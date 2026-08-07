import AppKit

/// Owns the menu-bar item and wires together toggling, the auto-off safety
/// monitor, the login item, and the right-click menu.
///
/// Icon states (SF Symbols):
///   moon.fill (template) → sleep allowed
///   bolt.fill (bold, yellow) → sleep disabled (stays awake)
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private var safety: SafetyMonitor!
    private let defaults = UserDefaults.standard

    // UserDefaults keys (Int; 0 means "off")
    private let kBattery = "batteryThresholdPercent"
    private let kHours = "timeLimitHours"
    private let kHeat = "heatPolicy"
    private let kHeatCeiling = "heatCeilingCelsius"
    private let kDidRegisterLogin = "didRegisterLoginItem"
    // Key string kept from the first version so an existing setting survives.
    private let kNetwork = "hotspotSSID"
    // Written on every auto-off so the menu can say why it happened.
    private let kLastTripReason = "lastTripReason"
    private let kLastTripAt = "lastTripAt"
    private let kLogSensors = "logThermalSensors"

    private var currentBattery: Int { defaults.integer(forKey: kBattery) }
    private var currentHours: Int { defaults.integer(forKey: kHours) }
    private var currentHeat: Int { defaults.integer(forKey: kHeat) }
    private var currentCeiling: Int { defaults.integer(forKey: kHeatCeiling) }

    /// Heat policies as menu entries. The tag is what gets persisted, so the
    /// codes stay stable even when labels or the order change.
    private static let heatPolicies: [(label: String, code: Int, policy: SafetyMonitor.HeatPolicy)] = [
        ("Off", 0, .off),
        ("Critical only", 1, .criticalOnly),
        ("Serious, immediately", 2, .serious(afterMinutes: 0)),
        ("Serious, after 2 min", 3, .serious(afterMinutes: 2)),
        ("Serious, after 5 min", 4, .serious(afterMinutes: 5)),
        ("Serious, after 10 min", 5, .serious(afterMinutes: 10))
    ]

    private static func heatPolicy(for code: Int) -> SafetyMonitor.HeatPolicy {
        heatPolicies.first { $0.code == code }?.policy ?? .serious(afterMinutes: 0)
    }

    /// Default network to switch to; `nil` when unset or blank.
    private var preferredNetwork: String? {
        let value = defaults.string(forKey: kNetwork)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        safety = SafetyMonitor(onTripped: { [weak self] reason in
            DispatchQueue.main.async { self?.handleSafetyTrip(reason) }
        })
        loadSafetySettings()
        if defaults.bool(forKey: kLogSensors) { dumpThermalSensors() }

        // Square (fixed) length: moon and bolt have different intrinsic widths;
        // a variable-length item would shift neighboring menu-bar icons on toggle.
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            // Hard cap: never let a stale, wrong-scale bitmap overflow the item.
            button.imageScaling = .scaleProportionallyDown
        }
        refreshIcon()

        // Rebuild the icon whenever displays are attached/detached or change
        // scale, discarding any image reps cached for the old configuration.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil)

        // The bolt turns orange under thermal pressure, so heat is visible
        // before the safety net ever acts on it.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(thermalStateChanged),
            name: ProcessInfo.thermalStateDidChangeNotification,
            object: nil)

        // Register as a login item on first launch (autostart is the default).
        if !defaults.bool(forKey: kDidRegisterLogin) {
            LoginItem.setEnabled(true)
            defaults.set(true, forKey: kDidRegisterLogin)
        }

        // Switching means pressing an entry in the Wi-Fi menu — ask for
        // accessibility access on launch so the grant is in place by the first
        // toggle instead of failing it.
        if preferredNetwork != nil, !WiFiMenu.isTrusted {
            WiFiMenu.requestTrust()
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
        // Staying awake is nearly always work away from the desk — offer the
        // network right after the switch, never when going back to sleep.
        if target { offerNetworkSwitch() }
    }

    /// Restores sleep and records why, so the menu can explain an auto-off the
    /// user was not around to see.
    ///
    /// A failed `pmset` call leaves the monitor running on purpose, so the next
    /// check tries again — and nothing is recorded, because no auto-off
    /// happened. No alert either: it would block this runloop, and there is
    /// nobody to read it behind a closed lid.
    private func handleSafetyTrip(_ reason: SafetyMonitor.TripReason) {
        guard SleepController.setSleepDisabled(false) else { return }
        safety.stop()
        defaults.set(reason.rawValue, forKey: kLastTripReason)
        defaults.set(Date().timeIntervalSince1970, forKey: kLastTripAt)
        refreshIcon()
    }

    // MARK: - Icon

    @objc private func screensChanged() {
        refreshIcon()
    }

    @objc private func thermalStateChanged() {
        DispatchQueue.main.async { self.refreshIcon() }
    }

    private func refreshIcon() {
        guard let button = statusItem.button else { return }
        let disabled = SleepController.isSleepDisabled()
        let hot = SafetyMonitor.isHot(ProcessInfo.processInfo.thermalState)
        let symbol = disabled ? "bolt.fill" : "moon.fill"
        let description: String
        switch (disabled, hot) {
        case (true, true): description = "Sleep disabled — running hot"
        case (true, false): description = "Sleep disabled — stays awake"
        case (false, _): description = "Sleep allowed"
        }

        // Same point size for both states so the icon doesn't visually jump.
        var config = NSImage.SymbolConfiguration(pointSize: 15, weight: disabled ? .bold : .regular)
        if disabled {
            config = config.applying(.init(paletteColors: [hot ? .systemOrange : .systemYellow]))
        }
        guard let symbolImage = NSImage(systemSymbolName: symbol, accessibilityDescription: description)?
            .withSymbolConfiguration(config) else {
            button.image = nil
            return
        }

        // Re-render through a drawing-handler image: the handler runs once per
        // backing scale, keeping the icon at its point size on mixed-DPI
        // multi-monitor setups. A plain symbol image would otherwise reuse one
        // screen's bitmap on another and appear oversized.
        let image = NSImage(size: symbolImage.size, flipped: false) { rect in
            symbolImage.draw(in: rect)
            return true
        }
        // The bolt keeps its yellow palette color (non-template) so the active
        // "stays awake" state stands out; the moon adapts to the menu bar.
        image.isTemplate = !disabled
        image.accessibilityDescription = description
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

        for line in [temperatureLine(), lastTripLine()].compactMap({ $0 }) {
            let item = NSMenuItem(title: line, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

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

        menu.addItem(submenuItem(
            title: "Auto-off on heat",
            options: Self.heatPolicies.map { ($0.label, $0.code) },
            selected: currentHeat,
            action: #selector(setHeatPolicy(_:))))

        // Only offered where a sensor actually answers — the thermal states
        // above work everywhere, this does not.
        if ThermalSensor.isAvailable {
            menu.addItem(submenuItem(
                title: "Auto-off above temperature",
                options: [("Off", 0), ("90 °C", 90), ("95 °C", 95), ("100 °C", 100),
                          ("105 °C", 105), ("110 °C", 110)],
                selected: currentCeiling,
                action: #selector(setHeatCeiling(_:))))
        }

        menu.addItem(.separator())

        let network = NSMenuItem(
            title: "Network: \(preferredNetwork ?? "not set") …",
            action: #selector(editNetworkName), keyEquivalent: "")
        network.target = self
        menu.addItem(network)

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

    /// "Temperature: 78 °C (serious)". Either half is dropped when it has
    /// nothing to say — no readable sensor, or a nominal thermal state — and
    /// the whole line disappears when both are silent.
    private func temperatureLine() -> String? {
        let celsius = ThermalSensor.hottestCelsius().map { "\(Int($0.rounded())) °C" }
        let state = Self.thermalLabel(ProcessInfo.processInfo.thermalState)
        switch (celsius, state) {
        case let (value?, label?): return "Temperature: \(value) (\(label))"
        case let (value?, nil): return "Temperature: \(value)"
        case let (nil, label?): return "Temperature: \(label)"
        case (nil, nil): return nil
        }
    }

    private static func thermalLabel(_ state: ProcessInfo.ThermalState) -> String? {
        switch state {
        case .nominal: return nil
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return nil
        }
    }

    /// "Last auto-off: heat — Today, 14:32", so an auto-off that happened
    /// while the lid was closed is not a mystery afterwards.
    private func lastTripLine() -> String? {
        let stamp = defaults.double(forKey: kLastTripAt)
        guard stamp > 0, let reason = defaults.string(forKey: kLastTripReason) else { return nil }
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return "Last auto-off: \(reason) — \(formatter.string(from: Date(timeIntervalSince1970: stamp)))"
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

    @objc private func setHeatPolicy(_ sender: NSMenuItem) {
        defaults.set(sender.tag, forKey: kHeat)
        safety.heatPolicy = Self.heatPolicy(for: sender.tag)
    }

    @objc private func setHeatCeiling(_ sender: NSMenuItem) {
        defaults.set(sender.tag, forKey: kHeatCeiling)
        safety.heatCeilingCelsius = sender.tag == 0 ? nil : sender.tag
    }

    @objc private func toggleLoginItem() {
        LoginItem.setEnabled(!LoginItem.isEnabled)
    }

    @objc private func editNetworkName() {
        askForNetworkName()
    }

    @objc private func showHelp() {
        showSudoersAlert(isHelp: true)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Settings

    private func loadSafetySettings() {
        // Defaults on first run: 20 % battery floor, 4 h time limit, sleep as
        // soon as the system reports serious thermal pressure. The absolute
        // °C ceiling stays off — it rests on a private API, so it is opt-in.
        if defaults.object(forKey: kBattery) == nil { defaults.set(20, forKey: kBattery) }
        if defaults.object(forKey: kHours) == nil { defaults.set(4, forKey: kHours) }
        if defaults.object(forKey: kHeat) == nil { defaults.set(2, forKey: kHeat) }
        if defaults.object(forKey: kHeatCeiling) == nil { defaults.set(0, forKey: kHeatCeiling) }
        safety.batteryThreshold = currentBattery == 0 ? nil : currentBattery
        safety.timeLimitHours = currentHours == 0 ? nil : Double(currentHours)
        safety.heatPolicy = Self.heatPolicy(for: currentHeat)
        // Read as a plain Int, so a value set with `defaults write` outside the
        // menu's choices works too.
        safety.heatCeilingCelsius = currentCeiling == 0 ? nil : currentCeiling
    }

    /// Prints every sensor both interfaces expose, so the key selection in
    /// `SMCSensor` and the name allowlist in `ThermalSensor` can be checked
    /// on an unfamiliar chip without a code change. Enable with:
    /// `defaults write com.philippjahn.SleepModeSwitcher logThermalSensors -bool YES`
    private func dumpThermalSensors() {
        let readings = SMCSensor.allReadings().map { (name: "SMC \($0.name)", celsius: $0.celsius) }
            + ThermalSensor.allReadings().map { (name: "HID \($0.name)", celsius: $0.celsius) }
        guard !readings.isEmpty else {
            fputs("thermal sensors: none readable\n", stderr)
            return
        }
        for reading in readings.sorted(by: { $0.celsius > $1.celsius }) {
            fputs(String(format: "thermal sensor %@ = %.1f °C\n", reading.name, reading.celsius), stderr)
        }
    }

    // MARK: - Network switching

    /// Asked on every switch to "sleep disabled": staying awake usually means
    /// working away from the desk, where the uplink changes too.
    ///
    /// Three answers, because the stored network is a default and not a rule:
    /// join it, pick another one, or stay put.
    private func offerNetworkSwitch() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Switch network?"
        let configured = preferredNetwork
        alert.informativeText = configured.map { "Sleep is now disabled. Join \"\($0)\"?" }
            ?? "Sleep is now disabled. No network set."

        if configured != nil {
            alert.addButton(withTitle: "Switch")     // default, triggered by Return
            alert.addButton(withTitle: "Other …")
        } else {
            alert.addButton(withTitle: "Choose …")
        }
        alert.addButton(withTitle: "Not now")
        alert.buttons.last?.keyEquivalent = "\u{1b}" // Escape

        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            if let name = configured {
                joinNetwork(named: name)
            } else {
                // Nothing set yet, so remember what gets picked.
                offerNetworkChoice(rememberPick: true)
            }
        case .alertSecondButtonReturn where configured != nil:
            offerNetworkChoice(rememberPick: false)
        default:
            break
        }
    }

    /// Reads the Wi-Fi menu, then lets the user pick from it. The menu read
    /// blocks, hence the background queue.
    private func offerNetworkChoice(rememberPick: Bool) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = WiFiMenu.availableNetworks()
            DispatchQueue.main.async {
                switch result {
                case .success(let networks):
                    guard !networks.isEmpty else {
                        self.showNetworkFailureAlert(name: nil, error: .entryNotFound(seen: []))
                        return
                    }
                    guard let pick = self.askToPick(from: networks) else { return }
                    if rememberPick { self.defaults.set(pick, forKey: self.kNetwork) }
                    self.joinNetwork(named: pick)
                case .failure(let error):
                    self.showNetworkFailureAlert(name: nil, error: error)
                }
            }
        }
    }

    private func askToPick(from networks: [String]) -> String? {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Network"
        alert.informativeText = "Pick the network to join."
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 260, height: 26))
        popup.addItems(withTitles: networks)
        alert.accessoryView = popup
        alert.addButton(withTitle: "Switch")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return popup.titleOfSelectedItem
    }

    /// Prompts for the default network and stores it. Returns the stored name,
    /// or `nil` when cancelled or left blank.
    @discardableResult
    private func askForNetworkName() -> String? {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Network"
        alert.informativeText = "Name as shown in the Wi-Fi menu."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "e.g. MyAI"
        field.stringValue = preferredNetwork ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        defaults.set(name, forKey: kNetwork)
        // Driving the Wi-Fi menu needs accessibility access — ask now rather
        // than letting the first switch fail on it.
        if !name.isEmpty, !WiFiMenu.isTrusted { WiFiMenu.requestTrust() }
        return name.isEmpty ? nil : name
    }

    /// Presses the network's entry in the Wi-Fi menu, off the main thread —
    /// opening the panel and waiting for its rows takes a moment.
    ///
    /// Connecting itself is left to macOS: a sleeping personal hotspot is woken
    /// first, so the link comes up seconds after the press. The menu bar shows
    /// the result, which is why no confirmation is polled here.
    private func joinNetwork(named name: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = WiFiMenu.join(name: name)
            DispatchQueue.main.async {
                if case .failure(let error) = result {
                    self.showNetworkFailureAlert(name: name, error: error)
                }
            }
        }
    }

    private func showNetworkFailureAlert(name: String?, error: WiFiMenu.MenuError) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = name.map { "Could not join \"\($0)\"" } ?? "Could not read the Wi-Fi menu"

        // The two failures the user can actually fix get an action button.
        var offersAccessibilitySettings = false
        var offersRename = false

        switch error {
        case .accessibilityNotTrusted:
            offersAccessibilitySettings = true
            alert.informativeText = """
            Switching works by pressing the network's entry in the Wi-Fi menu, \
            which needs accessibility access.

            Allow "SleepModeSwitcher" under Privacy & Security → Accessibility, \
            then try again.
            """
        case .controlCenterNotRunning:
            alert.informativeText = "Control Center is not running, so the Wi-Fi menu is unavailable."
        case .wifiMenuNotFound:
            alert.informativeText = """
            No Wi-Fi item was found in the menu bar. Enable it under Control \
            Center settings ("Show in Menu Bar").
            """
        case .entryNotFound(let seen):
            offersRename = name != nil
            alert.informativeText = seen.isEmpty
                ? "The Wi-Fi menu listed no networks. Is Wi-Fi switched off?"
                : """
                The Wi-Fi menu lists: \(seen.joined(separator: ", ")).

                The name has to match one of these exactly.
                """
        case .pressFailed(let message):
            alert.informativeText = message
        }

        if offersAccessibilitySettings {
            alert.addButton(withTitle: "Open Accessibility Settings")
            alert.addButton(withTitle: "Cancel")
        } else if offersRename {
            alert.addButton(withTitle: "Change name …")
            alert.addButton(withTitle: "Cancel")
        } else {
            alert.addButton(withTitle: "OK")
        }

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        if offersAccessibilitySettings {
            // Registers the app in the list; the pane is where it gets ticked.
            WiFiMenu.requestTrust()
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        } else if offersRename, let corrected = askForNetworkName() {
            joinNetwork(named: corrected)
        }
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
