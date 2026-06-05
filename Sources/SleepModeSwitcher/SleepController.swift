import Foundation

/// Thin wrapper around `pmset` for toggling and reading the system-wide
/// "disable sleep" kernel flag (`SleepDisabled`).
///
/// `pmset -a disablesleep 1` is the only mechanism that keeps an Apple Silicon
/// Mac awake with the lid closed and no external display — power assertions
/// (caffeinate, IOPMAssertion) do not override lid close. See README.
enum SleepController {

    /// Reads the current system state: is sleep currently disabled?
    ///
    /// Parses `pmset -g`. The flag shows up as `SleepDisabled <0|1>` when set;
    /// the parser tolerates both `SleepDisabled` and `disablesleep` spellings
    /// and any whitespace between the key and value.
    static func isSleepDisabled() -> Bool {
        guard let output = run("/usr/bin/pmset", ["-g"]) else { return false }
        for rawLine in output.lowercased().split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.contains("sleepdisabled") || line.contains("disablesleep") else { continue }
            let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            return tokens.last == "1"
        }
        return false
    }

    /// Enables/disables sleep via `pmset`. Returns `true` on success.
    ///
    /// Uses `sudo -n` (non-interactive) so a missing NOPASSWD sudoers rule
    /// fails fast with a non-zero status instead of hanging on a password
    /// prompt the user can never see (this is a GUI app). On failure the
    /// caller should point the user at `scripts/install-sudoers.sh`.
    @discardableResult
    static func setSleepDisabled(_ disabled: Bool) -> Bool {
        let value = disabled ? "1" : "0"
        return runStatus("/usr/bin/sudo",
                         ["-n", "/usr/bin/pmset", "-a", "disablesleep", value]) == 0
    }

    // MARK: - Process helpers

    private static func run(_ path: String, _ args: [String]) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = args
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do {
            try task.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }

    private static func runStatus(_ path: String, _ args: [String]) -> Int32 {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = args
        task.standardOutput = Pipe()
        task.standardError = Pipe()
        do {
            try task.run()
        } catch {
            return -1
        }
        task.waitUntilExit()
        return task.terminationStatus
    }
}
