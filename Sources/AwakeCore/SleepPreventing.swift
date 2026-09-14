import Foundation
import IOKit.pwr_mgt

/// Capability 1: blocks *idle* sleep via IOKit power assertions.
/// Does nothing for clamshell sleep — that needs the privileged helper.
@MainActor
public protocol SleepPreventing {
    func begin(keepDisplayAwake: Bool) throws
    func end()
}

public enum SleepPreventerError: LocalizedError {
    case assertionFailed(type: String, code: Int32)

    public var errorDescription: String? {
        switch self {
        case .assertionFailed(let type, let code):
            return "Couldn't create the \(type) power assertion (IOKit error \(code))."
        }
    }
}

@MainActor
public final class IOKitSleepPreventer: SleepPreventing {
    /// Shows up under this name in `pmset -g assertions`.
    /// ASCII only — pmset renders non-ASCII (an em-dash here) as a replacement
    /// character, which defeats the point of a recognisable name.
    public static let reason = "Awake: user-requested session"

    private var ids: [IOPMAssertionID] = []

    public init() {}

    public func begin(keepDisplayAwake: Bool) throws {
        releaseAll()
        try create(kIOPMAssertionTypePreventUserIdleSystemSleep)
        if keepDisplayAwake {
            // Also holds off the idle screensaver.
            do {
                try create(kIOPMAssertionTypePreventUserIdleDisplaySleep)
            } catch {
                releaseAll()  // never leave a half-built session behind
                throw error
            }
        }
    }

    public func end() {
        releaseAll()
    }

    public var assertionCount: Int { ids.count }

    private func create(_ type: String) throws {
        var id = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(
            type as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            Self.reason as CFString,
            &id
        )
        guard result == kIOReturnSuccess else {
            throw SleepPreventerError.assertionFailed(type: type, code: result)
        }
        ids.append(id)
    }

    private func releaseAll() {
        ids.forEach { IOPMAssertionRelease($0) }
        ids.removeAll()
    }
}

@MainActor
public final class MockSleepPreventer: SleepPreventing {
    public private(set) var beginCount = 0
    public private(set) var endCount = 0
    public private(set) var lastKeepDisplayAwake: Bool?
    public var errorToThrow: Error?

    public init() {}

    public func begin(keepDisplayAwake: Bool) throws {
        if let errorToThrow { throw errorToThrow }
        beginCount += 1
        lastKeepDisplayAwake = keepDisplayAwake
    }

    public func end() {
        endCount += 1
    }
}
