import Foundation
import IOKit

/// CPU core temperatures from the AppleSMC user client — the numbers iStat
/// and Stats label "CPU". On recent Apple silicon (M3/M4) the per-core
/// sensors (`Tp…` performance, `Te…` efficiency) exist only here; the HID
/// interface `ThermalSensor` reads exposes just the PMU package sensors,
/// which sit 20–30 °C below the hottest core under load.
///
/// AppleSMC is undocumented but has kept this call shape stable for many
/// macOS generations, and needs neither root nor an entitlement. Every step
/// degrades to `nil` on failure, which `ThermalSensor` answers by falling
/// back to its HID route.
///
/// Main thread only — the caches are not synchronized.
enum SMCSensor {

    // MARK: - Reading

    /// Hottest CPU core in °C, or `nil` when the SMC route is unusable.
    ///
    /// Idle cores are power-gated and their sensors then read 0, so any one
    /// key can go dark between samples; the maximum over all core keys stays
    /// meaningful regardless. Cached briefly, like `ThermalSensor`.
    static func hottestCPUCelsius() -> Double? {
        if let cached = cachedHottest, Date().timeIntervalSince(cached.at) < cacheLifetime {
            return cached.celsius
        }
        if let celsius = hottest() { return celsius }
        // A connection can go stale (SMC reset, ungraceful wake); every read
        // then fails. Drop everything and try once more before giving up —
        // but only when there were keys to read: a machine without matching
        // keys is a permanent condition, and re-enumerating thousands of SMC
        // keys on every sample would not change it.
        guard cachedCPUKeys?.isEmpty == false else { return nil }
        invalidate()
        return hottest()
    }

    /// Every temperature key (`T…`) with a plausible reading. Diagnostics
    /// only — this reads all of them and is correspondingly slow.
    static func allReadings() -> [(name: String, celsius: Double)] {
        guard let connection = connection(), let keys = allKeys(connection) else { return [] }
        return keys.compactMap { key in
            let keyName = name(of: key)
            guard keyName.hasPrefix("T") else { return nil }
            return celsius(of: key, connection).map { (keyName, $0) }
        }
    }

    private static func hottest() -> Double? {
        guard let connection = connection() else { return nil }
        guard let celsius = cpuKeys(connection)
            .compactMap({ celsius(of: $0, connection) })
            .max()
        else { return nil }
        cachedHottest = (celsius, Date())
        return celsius
    }

    /// The CPU core keys, resolved once — the hardware does not change while
    /// running. The curated per-generation list comes first; only when none
    /// of its keys answer (an unknown future chip) does the prefix sweep run.
    private static func cpuKeys(_ connection: io_connect_t) -> [UInt32] {
        if let cachedCPUKeys { return cachedCPUKeys }

        let curated = curatedCoreKeys().map(fourCC).filter { key in
            keyInfo(key, connection).map { name(of: $0.dataType) == "flt " } ?? false
        }
        if !curated.isEmpty {
            cachedCPUKeys = curated
            return curated
        }

        // Unknown generation (or renamed keys): sweep everything under the
        // CPU prefixes. This overshoots by ~10 °C where hotspot sensors
        // exist, but beats having no reading at all.
        guard let keys = allKeys(connection) else { return [] }
        let swept = keys.filter { key in
            guard cpuPrefixes.contains(where: name(of: key).hasPrefix) else { return false }
            // Apple silicon core sensors are all `flt`; the type check keeps
            // unrelated same-prefix keys on other machines (Intel is `sp78`
            // territory) from masquerading as a CPU core.
            return keyInfo(key, connection).map { name(of: $0.dataType) == "flt " } ?? false
        }
        cachedCPUKeys = swept
        return swept
    }

    /// The per-core sensor keys the Stats app has mapped out, per chip
    /// generation. The SMC exposes further sensors under the same prefixes —
    /// per-core hotspots and cluster maxima that run ~10 °C above the core
    /// reading — and sweeping those in showed values consistently hotter than
    /// what iStat and Stats display. Key names also collide across
    /// generations (M5 core keys are M4 hotspot keys), so the selection must
    /// be per-generation rather than one union.
    private static func curatedCoreKeys() -> [String] {
        switch generation() {
        case "M1":
            return ["Tp01", "Tp05", "Tp0D", "Tp0H", "Tp0L", "Tp0P", "Tp0X", "Tp0b",
                    "Tp09", "Tp0T"]
        case "M2":
            return ["Tp01", "Tp05", "Tp09", "Tp0D", "Tp0X", "Tp0b", "Tp0f", "Tp0j",
                    "Tp1h", "Tp1l", "Tp1p", "Tp1t"]
        case "M3":
            return ["Tf04", "Tf09", "Tf0A", "Tf0B", "Tf0D", "Tf0E",
                    "Tf44", "Tf49", "Tf4A", "Tf4B", "Tf4D", "Tf4E",
                    "Te05", "Te0L", "Te0P", "Te0S"]
        case "M4":
            return ["Tp01", "Tp05", "Tp09", "Tp0D", "Tp0V", "Tp0Y", "Tp0b", "Tp0e",
                    "Te05", "Te09", "Te0H", "Te0S"]
        case "M5":
            return ["Tp00", "Tp04", "Tp08", "Tp0C", "Tp0G", "Tp0K",
                    "Tp0O", "Tp0R", "Tp0U", "Tp0X", "Tp0a", "Tp0d",
                    "Tp0g", "Tp0j", "Tp0m", "Tp0p", "Tp0u", "Tp0y"]
        default:
            return []
        }
    }

    /// "M4" from a brand string like "Apple M4 Pro", or `nil` off Apple
    /// silicon — Intel brand strings carry no such token.
    private static func generation() -> String? {
        var size = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 0
        else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0) == 0
        else { return nil }
        return String(cString: buffer)
            .split(separator: " " as Character)
            .first { $0.first == "M" && $0.dropFirst().allSatisfy(\.isNumber) && $0.count > 1 }
            .map(String.init)
    }

    /// Prefix-sweep fallback only: `Tp…` performance cores, `Te…` efficiency
    /// cores. GPU (`Tg…`), skin, NAND and the rest stay out — the ceiling and
    /// the status line are about the CPU.
    private static let cpuPrefixes = ["Tp", "Te"]

    /// Power-gated cores read 0 (some report small constants like -4 or 5),
    /// and disconnected parts report absurd values — same idea as in
    /// `ThermalSensor`.
    private static let plausibleCelsius = 10.0...130.0

    // MARK: - SMC plumbing

    private static let kSMCHandleYPCEvent: UInt32 = 2
    private static let kSMCReadKey: UInt8 = 5
    private static let kSMCGetKeyFromIndex: UInt8 = 8
    private static let kSMCGetKeyInfo: UInt8 = 9

    private static var cachedConnection: io_connect_t?
    private static var cachedCPUKeys: [UInt32]?
    private static var cachedHottest: (celsius: Double, at: Date)?
    private static let cacheLifetime: TimeInterval = 2

    private static func connection() -> io_connect_t? {
        if let cachedConnection { return cachedConnection }
        let service = IOServiceGetMatchingService(kIOMainPortDefault,
                                                  IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        var connection: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == kIOReturnSuccess
        else { return nil }
        cachedConnection = connection
        return connection
    }

    private static func invalidate() {
        if let cachedConnection { IOServiceClose(cachedConnection) }
        cachedConnection = nil
        cachedCPUKeys = nil
        cachedHottest = nil
    }

    /// All keys the SMC reports, or `nil` when even the key count is
    /// unreadable — the distinction keeps a dead connection from being
    /// cached as "this machine has no CPU keys".
    private static func allKeys(_ connection: io_connect_t) -> [UInt32]? {
        let countKey = fourCC("#KEY")
        guard let info = keyInfo(countKey, connection),
              let bytes = readBytes(countKey, info, connection),
              bytes.count >= 4
        else { return nil }
        let count = bytes.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }

        var keys: [UInt32] = []
        for index in 0..<count {
            var input = SMCParamStruct()
            input.data8 = kSMCGetKeyFromIndex
            input.data32 = index
            guard let output = call(&input, connection) else { continue }
            keys.append(output.key)
        }
        return keys
    }

    private static func celsius(of key: UInt32, _ connection: io_connect_t) -> Double? {
        guard let info = keyInfo(key, connection),
              let bytes = readBytes(key, info, connection),
              let celsius = decode(bytes, type: info.dataType)
        else { return nil }
        return plausibleCelsius.contains(celsius) ? celsius : nil
    }

    private static func keyInfo(_ key: UInt32, _ connection: io_connect_t) -> SMCKeyInfoData? {
        var input = SMCParamStruct()
        input.key = key
        input.data8 = kSMCGetKeyInfo
        return call(&input, connection)?.keyInfo
    }

    private static func readBytes(_ key: UInt32, _ info: SMCKeyInfoData,
                                  _ connection: io_connect_t) -> [UInt8]? {
        guard info.dataSize <= 32 else { return nil }
        var input = SMCParamStruct()
        input.key = key
        input.keyInfo.dataSize = info.dataSize
        input.data8 = kSMCReadKey
        guard let output = call(&input, connection) else { return nil }
        return withUnsafeBytes(of: output.bytes) { Array($0.prefix(Int(info.dataSize))) }
    }

    /// The two encodings temperatures come in: `flt` (little-endian Float32,
    /// Apple silicon) and `sp78` (big-endian signed 7.8 fixed point, Intel —
    /// only reachable through `allReadings`).
    private static func decode(_ bytes: [UInt8], type: UInt32) -> Double? {
        switch name(of: type) {
        case "flt ":
            guard bytes.count >= 4 else { return nil }
            let raw = bytes.withUnsafeBytes { $0.load(as: UInt32.self) }
            return Double(Float(bitPattern: UInt32(littleEndian: raw)))
        case "sp78":
            guard bytes.count >= 2 else { return nil }
            return Double(Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))) / 256
        default:
            return nil
        }
    }

    private static func call(_ input: inout SMCParamStruct,
                             _ connection: io_connect_t) -> SMCParamStruct? {
        var output = SMCParamStruct()
        var outputSize = MemoryLayout<SMCParamStruct>.stride
        let status = IOConnectCallStructMethod(connection, kSMCHandleYPCEvent,
                                               &input, MemoryLayout<SMCParamStruct>.stride,
                                               &output, &outputSize)
        guard status == kIOReturnSuccess, output.result == 0 else { return nil }
        return output
    }

    private static func fourCC(_ string: String) -> UInt32 {
        string.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    private static func name(of fourCC: UInt32) -> String {
        let bytes = [UInt8(truncatingIfNeeded: fourCC >> 24),
                     UInt8(truncatingIfNeeded: fourCC >> 16),
                     UInt8(truncatingIfNeeded: fourCC >> 8),
                     UInt8(truncatingIfNeeded: fourCC)]
        return String(bytes: bytes, encoding: .ascii) ?? "????"
    }

    // MARK: - Wire format

    /// `SMCParamStruct` as AppleSMC expects it over
    /// `IOConnectCallStructMethod` — 80 bytes. The explicit `padding` field
    /// reproduces C's struct padding, which Swift does not insert on its own;
    /// without it every field after `keyInfo` lands 3 bytes early and the SMC
    /// rejects the call.
    private struct SMCVersion {
        var major: UInt8 = 0, minor: UInt8 = 0, build: UInt8 = 0
        var reserved: UInt8 = 0
        var release: UInt16 = 0
    }

    private struct SMCPLimitData {
        var version: UInt16 = 0, length: UInt16 = 0
        var cpuPLimit: UInt32 = 0, gpuPLimit: UInt32 = 0, memPLimit: UInt32 = 0
    }

    private struct SMCKeyInfoData {
        var dataSize: UInt32 = 0
        var dataType: UInt32 = 0
        var dataAttributes: UInt8 = 0
    }

    private struct SMCParamStruct {
        var key: UInt32 = 0
        var vers = SMCVersion()
        var pLimitData = SMCPLimitData()
        var keyInfo = SMCKeyInfoData()
        var padding: UInt16 = 0
        var result: UInt8 = 0
        var status: UInt8 = 0
        var data8: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
            (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
             0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    }
}
