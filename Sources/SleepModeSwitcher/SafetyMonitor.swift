import Foundation
import IOKit.ps

/// Auto-off safety net. While sleep is disabled this watches two thresholds and
/// calls `onTripped` (which re-enables sleep) when either is crossed:
///
///  - **Battery floor** – on battery and charge ≤ threshold percent.
///  - **Time limit** – more than N hours since activation.
///
/// This guards the lid-closed-on-battery use case from silently draining the
/// battery flat. Either threshold can be disabled (`nil`).
final class SafetyMonitor {

    var batteryThreshold: Int?    // percent (0–100), nil = off
    var timeLimitHours: Double?   // hours, nil = off

    private var timer: Timer?
    private var activatedAt: Date?
    private let onTripped: () -> Void

    init(onTripped: @escaping () -> Void) {
        self.onTripped = onTripped
    }

    /// Begin watching. Call when sleep has just been disabled.
    func start() {
        activatedAt = Date()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.check()
        }
    }

    /// Stop watching. Call when sleep is re-enabled.
    func stop() {
        timer?.invalidate()
        timer = nil
        activatedAt = nil
    }

    private func check() {
        if let hours = timeLimitHours, let started = activatedAt,
           Date().timeIntervalSince(started) >= hours * 3600 {
            trip()
            return
        }
        if let threshold = batteryThreshold,
           let (percent, onAC) = Self.batteryState(), !onAC, percent <= threshold {
            trip()
            return
        }
    }

    private func trip() {
        stop()
        onTripped()
    }

    /// Current internal battery state as `(percent 0–100, isOnAC)`, or `nil`
    /// when no battery is present (e.g. a desktop Mac) or info is unavailable.
    static func batteryState() -> (percent: Int, onAC: Bool)? {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }

        for source in sources {
            guard let desc = IOPSGetPowerSourceDescription(snapshot, source)?
                    .takeUnretainedValue() as? [String: Any],
                  let current = desc[kIOPSCurrentCapacityKey] as? Int,
                  let max = desc[kIOPSMaxCapacityKey] as? Int, max > 0
            else { continue }

            let percent = Int((Double(current) / Double(max)) * 100.0)
            let onAC = (desc[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            return (percent, onAC)
        }
        return nil
    }
}
