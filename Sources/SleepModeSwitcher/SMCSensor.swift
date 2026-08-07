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
        // then fails. Drop everything and try once more before giving up.
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

    /// The CPU core keys, resolved once. Enumerating all keys means a few
    /// thousand calls, so the result is kept for the lifetime of the process
    /// — the hardware does not change while running.
    private static func cpuKeys(_ connection: io_connect_t) -> [UInt32] {
        if let cachedCPUKeys { return cachedCPUKeys }
        guard let keys = allKeys(connection) else { return [] }

        let cpu = keys.filter { key in
            guard cpuPrefixes.contains(where: name(of: key).hasPrefix) else { return false }
            // Apple silicon core sensors are all `flt`; the type check keeps
            // unrelated same-prefix keys on other machines (Intel is `sp78`
            // territory) from masquerading as a CPU core.
            return keyInfo(key, connection).map { name(of: $0.dataType) == "flt " } ?? false
        }
        cachedCPUKeys = cpu
        return cpu
    }

    /// CPU core sensors in Apple silicon's SMC naming: `Tp…` performance
    /// cores, `Te…` efficiency cores. GPU (`Tg…`), skin, NAND and the rest
    /// stay out — the ceiling and the status line are about the CPU.
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
