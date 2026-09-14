import Foundation
import ServiceManagement

/// Capability 2: overrides *clamshell* sleep, which power assertions cannot touch.
///
/// The only lever without an external display is the undocumented `SleepDisabled`
/// pmset setting, and writing it needs root — hence a privileged helper. Reading it
/// back does not, so `currentState()` works even when the helper is absent, which is
/// what makes launch-time recovery possible on an un-helpered install.
@MainActor
public protocol LidSleepOverriding {
    var isAvailable: Bool { get }
    func disableLidSleep() async throws
    func restoreLidSleep() async throws
    /// `true` when the system `SleepDisabled` flag is set.
    func currentState() async throws -> Bool
}

public enum LidSleepError: LocalizedError, Equatable {
    case helperUnavailable
    case writeDidNotTake(wanted: Bool, got: Bool)
    case helperFailed(String)

    public var errorDescription: String? {
        switch self {
        case .helperUnavailable:
            "The lid-closed helper isn't installed, so this session will only prevent idle sleep."
        case .writeDidNotTake(let wanted, let got):
            "Tried to set SleepDisabled to \(wanted ? 1 : 0) but it read back as \(got ? 1 : 0)."
        case .helperFailed(let message):
            "The lid-closed helper failed: \(message)"
        }
    }
}

/// Reads `SleepDisabled` directly and delegates writes to the privileged daemon.
@MainActor
public final class HelperLidSleepOverride: LidSleepOverriding {
    /// Must match the launchd plist embedded at Contents/Library/LaunchDaemons/.
    public static let daemonPlistName = "com.vishwam.Awake.LidHelper.plist"

    public init() {}

    /// False until the daemon is both embedded in the bundle *and* registered. A
    /// missing plist reports `.notFound`, so an un-helpered build degrades honestly
    /// instead of pretending the capability exists.
    public var isAvailable: Bool {
        SMAppService.daemon(plistName: Self.daemonPlistName).status == .enabled
    }

    public func currentState() async throws -> Bool {
        Self.parseSleepDisabled(Self.pmsetOutput())
    }

    public func disableLidSleep() async throws {
        try await set(true)
    }

    public func restoreLidSleep() async throws {
        try await set(false)
    }

    private func set(_ wanted: Bool) async throws {
        guard isAvailable else { throw LidSleepError.helperUnavailable }
        try await LidHelperClient.shared.setSleepDisabled(wanted)

        // `SleepDisabled` is undocumented — never assume the write landed.
        let actual = try await currentState()
        guard actual == wanted else {
            throw LidSleepError.writeDidNotTake(wanted: wanted, got: actual)
        }
    }

    // MARK: - pmset parsing

    /// `pmset -g assertions` does *not* list this flag; `pmset -g` does, and only
    /// once it has been set at least once — absent means off.
    public static func parseSleepDisabled(_ output: String) -> Bool {
        for line in output.split(separator: "\n") {
            let fields = line.split(whereSeparator: \.isWhitespace)
            if fields.count >= 2, fields[0] == "SleepDisabled" {
                return fields[1] == "1"
            }
        }
        return false
    }

    public static func pmsetOutput() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g"]
        let pipe = Pipe()
        process.standardOutput = pipe
        guard (try? process.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}

@MainActor
public final class MockLidSleepOverride: LidSleepOverriding {
    public var isAvailable: Bool
    public var state = false
    public var errorToThrow: Error?
    /// Simulates the flag silently refusing to change, which is the failure mode
    /// `SleepDisabled` is known for.
    public var ignoreWrites = false

    public private(set) var disableCount = 0
    public private(set) var restoreCount = 0

    public init(isAvailable: Bool = true) {
        self.isAvailable = isAvailable
    }

    public func disableLidSleep() async throws {
        disableCount += 1
        if let errorToThrow { throw errorToThrow }
        guard isAvailable else { throw LidSleepError.helperUnavailable }
        if !ignoreWrites { state = true }
        guard state else { throw LidSleepError.writeDidNotTake(wanted: true, got: false) }
    }

    public func restoreLidSleep() async throws {
        restoreCount += 1
        if let errorToThrow { throw errorToThrow }
        if !ignoreWrites { state = false }
    }

    public func currentState() async throws -> Bool { state }
}
