import Foundation
import ServiceManagement

/// Registers the app as a Login Item via `SMAppService` (macOS 13+), so the
/// menu-bar icon reappears automatically after each login.
///
/// The user may have to approve the item once under
/// System Settings → General → Login Items.
enum LoginItem {

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
        } catch {
            NSLog("SleepModeSwitcher: login item update failed: \(error)")
        }
    }
}
