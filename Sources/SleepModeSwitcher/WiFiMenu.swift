import AppKit
import ApplicationServices

/// Joins a network by pressing its entry in the system Wi-Fi menu — the same
/// thing a manual click does. Any network the menu lists works, personal
/// hotspots included.
///
/// Going through the menu is not a detour but the only path that works:
/// `networksetup -setairportnetwork` and `CWInterface.associate` both fail with
/// `-3900 tmpErr` on macOS 26, because the network key lives in the System
/// keychain that no ordinary app may read. The menu succeeds because it *is*
/// the privileged system service — hence no password is needed, and a sleeping
/// personal hotspot gets woken over Bluetooth/iCloud on press.
///
/// The Control Center panel exposes each network as a checkbox whose
/// `AXIdentifier` is `wifi-network-<name>` — unlocalized and stable, unlike
/// the description ("MyAI, Persönlicher Hotspot, 3 Balken"), which is what the
/// entries are matched on.
enum WiFiMenu {

    enum MenuError: Error {
        case accessibilityNotTrusted
        case controlCenterNotRunning
        case wifiMenuNotFound
        /// The panel opened but held no entry with that name — `seen` carries
        /// the networks that were listed, which is what fixes a typo.
        case entryNotFound(seen: [String])
        case pressFailed(String)
    }

    private static let controlCenterBundleID = "com.apple.controlcenter"
    private static let wifiMenuIdentifier = "com.apple.menuextra.wifi"
    private static let networkPrefix = "wifi-network-"

    // MARK: - Accessibility trust

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system's "grant accessibility access" prompt.
    @discardableResult
    static func requestTrust() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    // MARK: - Joining

    /// Opens the Wi-Fi menu and presses the entry for `name`. Blocks for a few
    /// seconds — call off the main thread.
    static func join(name: String) -> Result<Void, MenuError> {
        let opened = openPanel()
        guard case .success(let menu) = opened else {
            return opened.map { _ in () }
        }

        // Network rows stream in after the panel itself, a sleeping personal
        // hotspot typically last — keep looking while the list fills.
        var listed: [String] = []
        for _ in 0..<16 {
            let entries = networkEntries(in: menu.panel)
            if let entry = entries.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                // Pressing a checked entry would disconnect it.
                guard !entry.isConnected else {
                    closeMenu(menu.item)
                    return .success(())
                }
                if AXUIElementPerformAction(entry.element, kAXPressAction as CFString) == .success {
                    return .success(())
                }
                closeMenu(menu.item)
                return .failure(.pressFailed("The entry \"\(name)\" could not be pressed."))
            }
            if !entries.isEmpty { listed = entries.map(\.name) }
            Thread.sleep(forTimeInterval: 0.25)
        }

        closeMenu(menu.item)
        return .failure(.entryNotFound(seen: listed))
    }

    /// The networks the Wi-Fi menu currently lists, in menu order — what the
    /// "other network" picker offers. Opens and closes the panel, so it blocks
    /// for a moment too.
    ///
    /// Networks hidden behind the collapsed "Other Networks" section are not
    /// included: the menu only builds those rows once expanded.
    static func availableNetworks() -> Result<[String], MenuError> {
        let opened = openPanel()
        guard case .success(let menu) = opened else {
            return opened.map { _ in [] }
        }
        defer { closeMenu(menu.item) }

        for _ in 0..<16 {
            let entries = networkEntries(in: menu.panel)
            if !entries.isEmpty { return .success(entries.map(\.name)) }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return .success([])
    }

    // MARK: - Panel

    private struct OpenMenu {
        let item: AXUIElement
        let panel: AXUIElement
    }

    private static func openPanel() -> Result<OpenMenu, MenuError> {
        guard AXIsProcessTrusted() else { return .failure(.accessibilityNotTrusted) }
        guard let app = NSRunningApplication
            .runningApplications(withBundleIdentifier: controlCenterBundleID).first else {
            return .failure(.controlCenterNotRunning)
        }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 5)

        guard let wifiItem = findWiFiMenuItem(in: appElement) else {
            return .failure(.wifiMenuNotFound)
        }
        guard AXUIElementPerformAction(wifiItem, kAXPressAction as CFString) == .success,
              let panel = waitForPanel(of: appElement) else {
            return .failure(.pressFailed("The Wi-Fi menu did not open."))
        }
        return .success(OpenMenu(item: wifiItem, panel: panel))
    }

    // MARK: - Menu bar

    private static func findWiFiMenuItem(in appElement: AXUIElement) -> AXUIElement? {
        // Menu extras hang off the extras menu bar; the plain menu bar and the
        // raw children are checked as fallbacks.
        let containers = [
            copyElement(appElement, "AXExtrasMenuBar"),
            copyElement(appElement, kAXMenuBarAttribute as String),
            appElement,
        ].compactMap { $0 }

        for container in containers {
            let items = children(of: container)
            if let match = items.first(where: { identifier(of: $0) == wifiMenuIdentifier }) {
                return match
            }
            // Localized fallback if Apple ever renames the identifier.
            if let match = items.first(where: { item in
                labels(of: item).contains { label in
                    let text = label.lowercased()
                    return text.contains("wi-fi") || text.contains("wifi") || text.contains("wlan")
                }
            }) {
                return match
            }
        }
        return nil
    }

    private static func waitForPanel(of appElement: AXUIElement) -> AXUIElement? {
        for _ in 0..<25 {
            if let window = children(of: appElement, attribute: kAXWindowsAttribute as String).first {
                return window
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return nil
    }

    private static func closeMenu(_ wifiItem: AXUIElement) {
        AXUIElementPerformAction(wifiItem, kAXCancelAction as CFString)
    }

    // MARK: - Network entries

    private struct Entry {
        let element: AXUIElement
        let name: String
        let isConnected: Bool
    }

    /// Every network row in the panel, identified by the `wifi-network-` prefix
    /// of its accessibility identifier.
    private static func networkEntries(in element: AXUIElement, depth: Int = 0) -> [Entry] {
        guard depth < 14 else { return [] }
        var found: [Entry] = []
        for child in children(of: element) {
            if let ident = identifier(of: child), ident.hasPrefix(networkPrefix) {
                let name = String(ident.dropFirst(networkPrefix.count))
                if !name.isEmpty {
                    found.append(Entry(element: child, name: name, isConnected: isChecked(child)))
                }
            }
            found.append(contentsOf: networkEntries(in: child, depth: depth + 1))
        }
        return found
    }

    private static func isChecked(_ element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success else {
            return false
        }
        return (value as? NSNumber)?.intValue == 1
    }

    // MARK: - AX helpers

    private static func children(of element: AXUIElement,
                                 attribute: String = kAXChildrenAttribute as String) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let array = value as? [AXUIElement] else {
            return []
        }
        return array
    }

    private static func copyElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let result = value, CFGetTypeID(result) == AXUIElementGetTypeID() else {
            return nil
        }
        return (result as! AXUIElement)
    }

    private static func identifier(of element: AXUIElement) -> String? {
        string(of: element, kAXIdentifierAttribute as String)
    }

    private static func labels(of element: AXUIElement) -> [String] {
        [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute]
            .compactMap { string(of: element, $0 as String) }
    }

    private static func string(of element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let text = value as? String, !text.isEmpty else {
            return nil
        }
        return text
    }
}
