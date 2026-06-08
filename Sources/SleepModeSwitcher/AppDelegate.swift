import AppKit

/// Owns the menu-bar item and wires together toggling, the auto-off safety
/// monitor, the login item, and the right-click menu.
///
/// Icon states (SF Symbols, template-rendered):
///   moon.fill → sleep allowed (normal)   bolt.fill → sleep disabled (stays awake)
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private var safety: SafetyMonitor!
    private let defaults = UserDefaults.standard

    // UserDefaults keys (Int; 0 means "off")
    private let kBattery = "batteryThresholdPercent"
    private let kHours = "timeLimitHours"
    private let kDidRegisterLogin = "didRegisterLoginItem"

    private var currentBattery: Int { defaults.integer(forKey: kBattery) }
    private var currentHours: Int { defaults.integer(forKey: kHours) }

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        safety = SafetyMonitor(onTripped: { [weak self] in
            DispatchQueue.main.async { self?.handleSafetyTrip() }
        })
        loadSafetySettings()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        refreshIcon()

        // Register as a login item on first launch (autostart is the default).
        if !defaults.bool(forKey: kDidRegisterLogin) {
            LoginItem.setEnabled(true)
            defaults.set(true, forKey: kDidRegisterLogin)
        }

        // If sleep was already disabled (e.g. set manually before launch),
        // begin guarding it immediately.
        if SleepController.isSleepDisabled() {
            safety.start()
        }
    }

    // MARK: - Click handling

    @objc private func statusItemClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showMenu()
        } else {
            toggle()
        }
    }

    private func toggle() {
        let target = !SleepController.isSleepDisabled()
        guard SleepController.setSleepDisabled(target) else {
            showSudoersAlert()
            return
        }
        if target { safety.start() } else { safety.stop() }
        refreshIcon()
    }

    private func handleSafetyTrip() {
        SleepController.setSleepDisabled(false)
        refreshIcon()
    }

    // MARK: - Icon

    private func refreshIcon() {
        guard let button = statusItem.button else { return }
        let disabled = SleepController.isSleepDisabled()
        let symbol = disabled ? "bolt.fill" : "moon.fill"
        let description = disabled ? "Sleep disabled — stays awake" : "Sleep allowed"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)
        image?.isTemplate = true
        button.image = image
    }

    // MARK: - Menu

    /// Builds the menu fresh on each right-click so checkmarks reflect current
    /// state, shows it, then clears `statusItem.menu` again so the next
    /// left-click is delivered to our action (toggle) rather than opening a menu.
    private func showMenu() {
        statusItem.menu = buildMenu()
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        let disabled = SleepController.isSleepDisabled()
        let status = NSMenuItem(
            title: disabled ? "Status: Sleep DISABLED (stays awake)" : "Status: Sleep allowed",
            action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())

        menu.addItem(submenuItem(
            title: "Auto-off on battery",
            options: [("Off", 0), ("10%", 10), ("20%", 20), ("30%", 30)],
            selected: currentBattery,
            action: #selector(setBatteryThreshold(_:))))

        menu.addItem(submenuItem(
            title: "Auto-off after time",
            options: [("Off", 0), ("1 h", 1), ("2 h", 2), ("4 h", 4), ("8 h", 8)],
            selected: currentHours,
            action: #selector(setTimeLimit(_:))))

        menu.addItem(.separator())

        let login = NSMenuItem(title: "Launch at login",
                               action: #selector(toggleLoginItem), keyEquivalent: "")
        login.target = self
        login.state = LoginItem.isEnabled ? .on : .off
        menu.addItem(login)

        let help = NSMenuItem(title: "Setup help …",
                              action: #selector(showHelp), keyEquivalent: "")
        help.target = self
        menu.addItem(help)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        return menu
    }

    private func submenuItem(title: String,
                             options: [(String, Int)],
                             selected: Int,
                             action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for (label, value) in options {
            let entry = NSMenuItem(title: label, action: action, keyEquivalent: "")
            entry.target = self
            entry.tag = value
            entry.state = (selected == value) ? .on : .off
            submenu.addItem(entry)
        }
        item.submenu = submenu
        return item
    }

    // MARK: - Menu actions

    @objc private func setBatteryThreshold(_ sender: NSMenuItem) {
        defaults.set(sender.tag, forKey: kBattery)
        safety.batteryThreshold = sender.tag == 0 ? nil : sender.tag
    }

    @objc private func setTimeLimit(_ sender: NSMenuItem) {
        defaults.set(sender.tag, forKey: kHours)
        safety.timeLimitHours = sender.tag == 0 ? nil : Double(sender.tag)
    }

    @objc private func toggleLoginItem() {
        LoginItem.setEnabled(!LoginItem.isEnabled)
    }

    @objc private func showHelp() {
        showSudoersAlert(isHelp: true)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Settings

    private func loadSafetySettings() {
        // Defaults on first run: 20 % battery floor, 4 h time limit.
        if defaults.object(forKey: kBattery) == nil { defaults.set(20, forKey: kBattery) }
        if defaults.object(forKey: kHours) == nil { defaults.set(4, forKey: kHours) }
        safety.batteryThreshold = currentBattery == 0 ? nil : currentBattery
        safety.timeLimitHours = currentHours == 0 ? nil : Double(currentHours)
    }

    // MARK: - Alerts

    private func showSudoersAlert(isHelp: Bool = false) {
        let alert = NSAlert()
        alert.alertStyle = isHelp ? .informational : .warning
        alert.messageText = isHelp
            ? "Setup help"
            : "Could not toggle sleep mode"
        alert.informativeText = """
        To toggle sleep mode without a password prompt, you must install a
        sudoers entry once.

        Run in Terminal from the project folder:
            ./scripts/install-sudoers.sh

        That allows only these two commands without a password:
            /usr/bin/pmset -a disablesleep 0
            /usr/bin/pmset -a disablesleep 1
        """
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
