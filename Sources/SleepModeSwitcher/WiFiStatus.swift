import CoreLocation
import CoreWLAN

/// Reads which network the Mac is currently on — the one piece the Wi-Fi menu
/// automation cannot answer without visibly opening the panel.
///
/// macOS 26 treats the SSID as location data and redacts it in every source
/// unless the app holds Location Services permission: `CWInterface.ssid()`,
/// `ipconfig getsummary`, the SC dynamic store, `system_profiler`, the IOKit
/// registry, even `wdutil info` as root. Hence the one-time permission
/// request; with it the read is instant and invisible. Denying it costs
/// nothing but the network question showing up every time.
enum WiFiStatus {

    /// Kept alive because the permission prompt is tied to the manager's
    /// lifetime. Created on first use — always from the main thread, which
    /// CLLocationManager requires for its delegate machinery.
    private static let locationManager = CLLocationManager()

    /// Shows the system's Location Services prompt once; later calls are
    /// no-ops. Call on the main thread.
    static func requestPermissionIfNeeded() {
        if locationManager.authorizationStatus == .notDetermined {
            locationManager.requestWhenInUseAuthorization()
        }
    }

    /// The connected network's name, or `nil` when there is none — or when
    /// the permission is missing, which callers treat the same way: unknown
    /// means ask.
    static func currentSSID() -> String? {
        CWWiFiClient.shared().interface()?.ssid()
    }
}
