import Foundation

/// Die temperatures from the IOKit HID sensor interface — the route Stats and
/// macmon take. It needs neither root nor an entitlement, but it is private
/// API, so every symbol is resolved through `dlsym` at runtime: a macOS release
/// that drops one degrades this to "no temperature available" instead of
/// breaking the build or the launch.
///
/// Nothing safety-critical depends on it. `SafetyMonitor` trips on the public
/// `ProcessInfo.thermalState`; the °C ceiling is opt-in and its menu is hidden
/// when no sensor answers.
///
/// Main thread only — the caches are not synchronized.
enum ThermalSensor {

    // MARK: - Reading

    /// True when the interface resolved and at least one sensor reads back a
    /// plausible value. Cached: the hardware does not change while running.
    static var isAvailable: Bool {
        if let known = availability { return known }
        let available = hottestCelsius() != nil
        availability = available
        return available
    }

    /// Hottest die sensor in °C, or `nil` when nothing is readable.
    ///
    /// Reading one sensor costs about a millisecond, so this only touches the
    /// pre-selected die sensors (14 of 77 services on an M4 Pro) and caches the
    /// result briefly — a menu build and a monitor check landing together then
    /// share one sweep.
    static func hottestCelsius() -> Double? {
        if let cached = cachedHottest, Date().timeIntervalSince(cached.at) < cacheLifetime {
            return cached.celsius
        }
        guard let symbols else { return nil }

        if let celsius = hottest(symbols) { return celsius }
        // Service lists do not survive every sleep/wake cycle. Drop everything
        // and try once more before reporting no sensor at all.
        invalidate()
        return hottest(symbols)
    }

    /// Every temperature sensor with a plausible reading, names included.
    /// Diagnostics only — this reads all of them and is correspondingly slow.
    static func allReadings() -> [(name: String, celsius: Double)] {
        guard let symbols else { return [] }
        return namedServices(symbols).compactMap { entry in
            celsius(of: entry.service, symbols).map { (entry.name, $0) }
        }
    }

    private static func hottest(_ symbols: Symbols) -> Double? {
        guard let celsius = dieSensors(symbols)
            .compactMap({ celsius(of: $0, symbols) })
            .max()
        else { return nil }
        cachedHottest = (celsius, Date())
        return celsius
    }

    /// One service per distinct die-sensor name, resolved once. Names repeat
    /// across services — 77 services expose 14 distinct sensors here — and
    /// every reading costs a millisecond, so the duplicates are dropped.
    private static func dieSensors(_ symbols: Symbols) -> [UnsafeMutableRawPointer] {
        if let cachedDieSensors { return cachedDieSensors }

        var seen = Set<String>()
        var preferred: [UnsafeMutableRawPointer] = []
        var rest: [UnsafeMutableRawPointer] = []
        for entry in namedServices(symbols) where seen.insert(entry.name).inserted {
            if preferredPrefixes.contains(where: { entry.name.hasPrefix($0) }) {
                preferred.append(entry.service)
            } else if !excludedFragments.contains(where: { entry.name.lowercased().contains($0) }) {
                rest.append(entry.service)
            }
        }
        // Sensor names differ per chip generation, so an empty allowlist match
        // is expected rather than exceptional — fall back to everything that is
        // not obviously a peripheral sensor.
        let sensors = preferred.isEmpty ? rest : preferred
        cachedDieSensors = sensors
        return sensors
    }

    private static func namedServices(
        _ symbols: Symbols
    ) -> [(name: String, service: UnsafeMutableRawPointer)] {
        guard let services = services(symbols) else { return [] }

        var entries: [(name: String, service: UnsafeMutableRawPointer)] = []
        for index in 0..<CFArrayGetCount(services) {
            guard let raw = CFArrayGetValueAtIndex(services, index) else { continue }
            let service = UnsafeMutableRawPointer(mutating: raw)
            guard let property = symbols.copyProperty(service, "Product" as CFString),
                  let name = property.takeRetainedValue() as? String
            else { continue }
            entries.append((name, service))
        }
        return entries
    }

    private static func celsius(of service: UnsafeMutableRawPointer,
                                _ symbols: Symbols) -> Double? {
        guard let event = symbols.copyEvent(service, temperatureEventType, 0, 0) else { return nil }
        let celsius = symbols.floatValue(event.toOpaque(), temperatureField)
        event.release()
        return plausibleCelsius.contains(celsius) ? celsius : nil
    }

    private static func invalidate() {
        cachedServices = nil
        cachedDieSensors = nil
        cachedHottest = nil
    }

    /// SoC die sensors, in the namings Apple silicon has used. An M4 Pro
    /// exposes `PMU tdie1`…`tdie14`; older chips report per-cluster names
    /// (`pACC`/`eACC`/`SOC`/`GPU`). Everything else — battery, NAND, chargers
    /// — is either far cooler or irrelevant here.
    private static let preferredPrefixes = [
        "PMU tdie", "PMU tdev", "pACC", "eACC", "SOC", "GPU", "ANE"
    ]

    /// `tcal` is a calibration reference rather than a live temperature; it
    /// only matters for the fallback path, which takes whatever is left.
    private static let excludedFragments = ["battery", "gas gauge", "nand", "tcal"]

    /// Readings outside this range are sensors that are not reporting a real
    /// temperature (disconnected parts report 0 or absurd values).
    private static let plausibleCelsius = 10.0...130.0

    // MARK: - IOHID plumbing

    /// `kIOHIDEventTypeTemperature`; the field id is `type << 16` per
    /// `IOHIDEventTypes.h`.
    private static let temperatureEventType: Int64 = 15
    private static let temperatureField: Int32 = 15 << 16

    /// `kHIDPage_AppleVendor` / `kHIDUsage_AppleVendor_TemperatureSensor`.
    private static let appleVendorUsagePage = 0xff00
    private static let temperatureUsage = 5

    private static var availability: Bool?
    private static var cachedClient: UnsafeMutableRawPointer?
    /// The array owns the service references — holding it keeps them alive,
    /// including the ones handed out through `cachedDieSensors`.
    private static var cachedServices: CFArray?
    private static var cachedDieSensors: [UnsafeMutableRawPointer]?
    private static var cachedHottest: (celsius: Double, at: Date)?
    private static let cacheLifetime: TimeInterval = 2

    private static func services(_ symbols: Symbols) -> CFArray? {
        if let cachedServices { return cachedServices }
        guard let client = client(symbols) else { return nil }

        let matching: [String: Any] = [
            "PrimaryUsagePage": appleVendorUsagePage,
            "PrimaryUsage": temperatureUsage
        ]
        // `SetMatching` returns void — the empty service list below is the only
        // signal that the match found nothing.
        symbols.setMatching(client, matching as CFDictionary)
        guard let services = symbols.copyServices(client)?.takeRetainedValue() else { return nil }

        cachedServices = services
        return services
    }

    private static func client(_ symbols: Symbols) -> UnsafeMutableRawPointer? {
        if let cachedClient { return cachedClient }
        // `CreateWithType` with the simple client type is the fallback for
        // releases where the plain create is gone or refuses.
        let client = symbols.create?(kCFAllocatorDefault)
            ?? symbols.createWithType?(kCFAllocatorDefault, 1, nil)
        cachedClient = client
        return client
    }

    private typealias CreateFn = @convention(c) (CFAllocator?) -> UnsafeMutableRawPointer?
    private typealias CreateWithTypeFn =
        @convention(c) (CFAllocator?, Int32, CFDictionary?) -> UnsafeMutableRawPointer?
    private typealias SetMatchingFn =
        @convention(c) (UnsafeMutableRawPointer, CFDictionary) -> Void
    private typealias CopyServicesFn =
        @convention(c) (UnsafeMutableRawPointer) -> Unmanaged<CFArray>?
    private typealias CopyPropertyFn =
        @convention(c) (UnsafeMutableRawPointer, CFString) -> Unmanaged<AnyObject>?
    private typealias CopyEventFn =
        @convention(c) (UnsafeMutableRawPointer, Int64, Int32, Int64) -> Unmanaged<AnyObject>?
    private typealias FloatValueFn =
        @convention(c) (UnsafeMutableRawPointer, Int32) -> Double

    private struct Symbols {
        let create: CreateFn?
        let createWithType: CreateWithTypeFn?
        let setMatching: SetMatchingFn
        let copyServices: CopyServicesFn
        let copyProperty: CopyPropertyFn
        let copyEvent: CopyEventFn
        let floatValue: FloatValueFn
    }

    /// Resolved once. `nil` when any required symbol is missing, which is the
    /// single point where a future macOS switches the whole feature off.
    private static let symbols: Symbols? = {
        guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY)
        else { return nil }

        func symbol<T>(_ name: String, as type: T.Type) -> T? {
            guard let pointer = dlsym(handle, name) else { return nil }
            return unsafeBitCast(pointer, to: type)
        }

        guard let setMatching = symbol("IOHIDEventSystemClientSetMatching", as: SetMatchingFn.self),
              let copyServices = symbol("IOHIDEventSystemClientCopyServices", as: CopyServicesFn.self),
              let copyProperty = symbol("IOHIDServiceClientCopyProperty", as: CopyPropertyFn.self),
              let copyEvent = symbol("IOHIDServiceClientCopyEvent", as: CopyEventFn.self),
              let floatValue = symbol("IOHIDEventGetFloatValue", as: FloatValueFn.self)
        else { return nil }

        return Symbols(
            create: symbol("IOHIDEventSystemClientCreate", as: CreateFn.self),
            createWithType: symbol("IOHIDEventSystemClientCreateWithType", as: CreateWithTypeFn.self),
            setMatching: setMatching,
            copyServices: copyServices,
            copyProperty: copyProperty,
            copyEvent: copyEvent,
            floatValue: floatValue)
    }()
}
