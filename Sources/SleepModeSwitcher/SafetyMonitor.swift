import Foundation
import IOKit.ps

/// Auto-off safety net. While sleep is disabled this watches three thresholds
/// and calls `onTripped` (which re-enables sleep and then calls `stop()`) when
/// one is crossed:
///
///  - **Heat** – system thermal pressure, optionally an absolute °C ceiling.
///  - **Battery floor** – on battery and charge ≤ threshold percent.
///  - **Time limit** – more than N hours since activation.
///
/// This guards the lid-closed use case: a silently drained battery, and a Mac
/// running full tilt inside a bag where no airflow ever cools it down. Every
/// threshold can be disabled (`nil` / `.off`).
final class SafetyMonitor {

    /// Why sleep was re-enabled. Raw values are persisted by `AppDelegate`.
    enum TripReason: String {
        case heat
        case battery
        case time
    }

    /// When thermal pressure re-enables sleep.
    ///
    /// macOS itself never sleeps a hot Mac — it throttles and, at the very
    /// end, shuts down to protect the hardware. Between those two points sits
    /// a long stretch of sustained heat that ages the battery and buys no
    /// performance, which is what this cuts short.
    enum HeatPolicy: Equatable {
        case off
        case criticalOnly
        /// Trip once the state has been `serious` (or worse) for this long;
        /// `0` trips on the first reading.
        case serious(afterMinutes: Int)
    }

    var batteryThreshold: Int?    // percent (0–100), nil = off
    var timeLimitHours: Double?   // hours, nil = off
    var heatPolicy: HeatPolicy = .serious(afterMinutes: 0)
    var heatCeilingCelsius: Int?  // °C, nil = off

    /// Heat trips stay disarmed this long after activation. Without it,
    /// switching to "stays awake" on an already-hot Mac would flip straight
    /// back under the default policy, and the button would look broken.
    /// Battery and time limits are unaffected.
    private static let armingGrace: TimeInterval = 120

    private var timer: Timer?
    private var activatedAt: Date?
    private var seriousSince: Date?
    private var ceilingHits = 0
    private var lastCeilingSample: Date?
    private let onTripped: (TripReason) -> Void
    private var thermalObserver: NSObjectProtocol?
    private var activity: NSObjectProtocol?

    init(onTripped: @escaping (TripReason) -> Void) {
        self.onTripped = onTripped
        // The 30 s timer alone would make "immediately" mean "within half a
        // minute" — the system's own thermal notification closes that gap.
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main) { [weak self] _ in
                self?.check()
            }
    }

    deinit {
        if let thermalObserver {
            NotificationCenter.default.removeObserver(thermalObserver)
        }
        endActivity()
    }

    private func endActivity() {
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
    }

    /// Begin watching. Call when sleep has just been disabled.
    func start() {
        // A background menu-bar app has its timers coalesced by App Nap —
        // measured here at well under the scheduled rate — which is not what a
        // safety net should run on. This asserts user-initiated work while
        // explicitly still allowing idle system sleep: keeping the Mac awake is
        // `pmset`'s job, and asserting it here as well would hold the machine
        // up if the activity ever outlived its purpose.
        endActivity()
        activity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep,
            reason: "Watching heat and battery while sleep is disabled")

        activatedAt = Date()
        seriousSince = Self.isHot(ProcessInfo.processInfo.thermalState) ? Date() : nil
        ceilingHits = 0
        lastCeilingSample = nil
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.check()
        }
    }

    /// Stop watching. Call when sleep is re-enabled.
    func stop() {
        endActivity()
        timer?.invalidate()
        timer = nil
        activatedAt = nil
        seriousSince = nil
        ceilingHits = 0
        lastCeilingSample = nil
    }

    private func check() {
        // Also reached from the thermal notification, which fires whether or
        // not we are currently guarding anything.
        guard let started = activatedAt else { return }
        let now = Date()
        updateSeriousSince(now: now)

        // Heat first: it is the only threshold that keeps getting worse while
        // the others merely count down.
        if now.timeIntervalSince(started) >= Self.armingGrace {
            if Self.heatTrips(policy: heatPolicy,
                              state: ProcessInfo.processInfo.thermalState,
                              seriousSince: seriousSince,
                              now: now) || ceilingTrips() {
                trip(.heat)
                return
            }
        }

        if let threshold = batteryThreshold,
           let (percent, onAC) = Self.batteryState(), !onAC, percent <= threshold {
            trip(.battery)
            return
        }

        if let hours = timeLimitHours, now.timeIntervalSince(started) >= hours * 3600 {
            trip(.time)
        }
    }

    /// Reports the crossed threshold and keeps watching. Stopping is the
    /// callback's job, once it has actually restored sleep — a `pmset` call
    /// that fails must not leave the Mac awake and unguarded, and restarting
    /// here instead would reset the time limit on every failed attempt.
    private func trip(_ reason: TripReason) {
        onTripped(reason)
    }

    // MARK: - Heat

    /// Whether the policy is satisfied. Pure, so the decision can be reasoned
    /// about (and exercised) without a hot Mac.
    static func heatTrips(policy: HeatPolicy,
                          state: ProcessInfo.ThermalState,
                          seriousSince: Date?,
                          now: Date) -> Bool {
        switch policy {
        case .off:
            return false
        case .criticalOnly:
            return state == .critical
        case .serious(let afterMinutes):
            // Critical never waits out a tolerance window.
            if state == .critical { return true }
            guard isHot(state), let since = seriousSince else { return false }
            return now.timeIntervalSince(since) >= Double(afterMinutes) * 60
        }
    }

    /// `serious` and `critical` are the two states macOS reports once the
    /// system is actively fighting heat rather than merely warm.
    static func isHot(_ state: ProcessInfo.ThermalState) -> Bool {
        state.rawValue >= ProcessInfo.ThermalState.serious.rawValue
    }

    private func updateSeriousSince(now: Date) {
        guard Self.isHot(ProcessInfo.processInfo.thermalState) else {
            seriousSince = nil
            return
        }
        if seriousSince == nil { seriousSince = now }
    }

    /// Absolute °C ceiling, opt-in and only as good as the private sensor API.
    /// Two consecutive samples are required so a single spike — or one bogus
    /// reading — cannot trip it.
    ///
    /// Sampling is by far the most expensive part of a check, and this is a
    /// slow net, so it keeps its own cadence no matter how often `check()`
    /// runs: without that, a flapping thermal state would both burn time and
    /// collect its two samples from what is effectively one instant.
    private func ceilingTrips() -> Bool {
        guard let ceiling = heatCeilingCelsius else {
            ceilingHits = 0
            return false
        }
        let now = Date()
        if let last = lastCeilingSample, now.timeIntervalSince(last) < 20 { return false }
        lastCeilingSample = now

        guard let celsius = ThermalSensor.hottestCelsius() else {
            ceilingHits = 0
            return false
        }
        ceilingHits = celsius >= Double(ceiling) ? ceilingHits + 1 : 0
        return ceilingHits >= 2
    }

    // MARK: - Battery

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
