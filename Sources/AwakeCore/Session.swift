import AppKit
import Foundation

public struct SessionOptions: Equatable, Sendable {
    public var keepDisplayAwake: Bool
    public var allowLidClosed: Bool

    public init(keepDisplayAwake: Bool = true, allowLidClosed: Bool = false) {
        self.keepDisplayAwake = keepDisplayAwake
        self.allowLidClosed = allowLidClosed
    }
}

public enum SessionState: Equatable {
    case idle
    case running(until: Date, options: SessionOptions)
    case indefinite(options: SessionOptions)

    public var isActive: Bool { self != .idle }

    public var options: SessionOptions? {
        switch self {
        case .idle: nil
        case .running(_, let o), .indefinite(let o): o
        }
    }

    public var endDate: Date? {
        if case .running(let until, _) = self { return until }
        return nil
    }
}

public enum SessionEnd: Equatable {
    case manual
    case expired
    case batteryFloor(Int)
    case failed(String)
}

@MainActor
public final class SessionController: ObservableObject {
    @Published public private(set) var state: SessionState = .idle
    /// Only reassigned when the rendered string actually changes — the tick is 1s,
    /// this changes far less often.
    @Published public private(set) var menuBarLabel: String = ""
    @Published public private(set) var remaining: TimeInterval = 0
    @Published public var lastError: String?
    /// Set when a session asked for lid-closed but couldn't get it. Surfaced in the
    /// UI so we never silently pretend the capability is active.
    @Published public private(set) var lidDegraded = false
    /// True while the system SleepDisabled flag is ours to restore.
    @Published public private(set) var lidOverrideActive = false

    private let preventer: SleepPreventing
    private let lid: LidSleepOverriding?
    private let now: () -> Date
    private var timer: Timer?
    private var batteryWarned = false
    private var ticksSinceBatteryCheck = 0

    /// Length the session was started with, including any extensions. 0 when indefinite.
    public private(set) var totalDuration: TimeInterval = 0
    /// Below this charge a session ends itself. Range enforced by the UI.
    public var batteryFloor: Int = 20
    public var notifyOnExpiry: Bool = true

    public init(
        preventer: SleepPreventing,
        lid: LidSleepOverriding? = nil,
        now: @escaping () -> Date = { Date() }
    ) {
        self.preventer = preventer
        self.lid = lid
        self.now = now
        NotificationCenter.default.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reassertAfterWake() }
        }
    }

    // MARK: - Derived state

    public var isRunning: Bool { state.isActive }

    /// Fraction of the session still to go, 1 -> 0. Indefinite sessions report 1.
    public var progress: Double {
        guard case .running = state, totalDuration > 0 else { return 1 }
        return min(1, max(0, remaining / totalDuration))
    }

    public var iconName: String {
        switch state {
        case .idle: "moon.zzz"
        case .running, .indefinite:
            lidOverrideActive ? "laptopcomputer.and.arrow.down" : "cup.and.saucer.fill"
        }
    }

    public var accessibilityLabel: String {
        switch state {
        case .idle: "Awake — sleep prevention off"
        case .running(let until, _): "Awake — active until \(TimeFormat.endTime(until))"
        case .indefinite: "Awake — active until turned off"
        }
    }

    public var lidAvailable: Bool { lid?.isAvailable ?? false }

    // MARK: - Launch recovery

    /// If `SleepDisabled` is set with no session running, a previous run was killed
    /// before it could restore it. Put it back and say so, rather than leaving the
    /// machine unable to sleep forever.
    public func recoverStaleLidOverrideIfNeeded() async {
        guard let lid, !state.isActive else { return }
        guard let stale = try? await lid.currentState(), stale else { return }

        do {
            try await lid.restoreLidSleep()
            lastError = "Awake didn't shut down cleanly last time, so your Mac was left "
                + "unable to sleep. That's been put back."
        } catch {
            lastError = "Your Mac is still set to never sleep from a previous Awake "
                + "session, and it couldn't be undone automatically. "
                + "Run: sudo pmset -a disablesleep 0"
        }
    }

    // MARK: - Lifecycle

    /// `duration == nil` starts an indefinite session. Lid-closed sessions always
    /// need a finite timer, so `allowLidClosed` is refused for indefinite ones.
    public func start(duration: TimeInterval?, options: SessionOptions) async {
        stop(reason: .manual)  // restart cleanly if one is already running

        // Clear carry-over from the previous session up front. Doing it later would
        // wipe a degrade this session has just recorded.
        lidDegraded = false
        lastError = nil

        var options = options
        if options.allowLidClosed && duration == nil {
            options.allowLidClosed = false
            lidDegraded = true
            lastError = "Lid-closed sessions need a finite timer, so this one runs with "
                + "idle-sleep prevention only."
        }

        do {
            try preventer.begin(keepDisplayAwake: options.keepDisplayAwake)
        } catch {
            lastError = error.localizedDescription
            state = .idle
            refresh()
            return
        }

        // Set up second so teardown can run in reverse order.
        if options.allowLidClosed {
            do {
                guard let lid, lid.isAvailable else { throw LidSleepError.helperUnavailable }
                try await lid.disableLidSleep()
                lidOverrideActive = true
            } catch {
                // Degrade to idle-sleep-only rather than claim a capability we lack.
                options.allowLidClosed = false
                lidDegraded = true
                lastError = error.localizedDescription
            }
        }

        batteryWarned = false
        ticksSinceBatteryCheck = 0

        if let duration {
            totalDuration = duration
            state = .running(until: now().addingTimeInterval(duration), options: options)
        } else {
            totalDuration = 0
            state = .indefinite(options: options)
        }
        startTimer()
        refresh()
    }

    @discardableResult
    public func stop(reason: SessionEnd = .manual) -> Bool {
        guard state.isActive else { return false }
        timer?.invalidate()
        timer = nil

        // Reverse order of setup: lid override down first, then the assertions.
        if lidOverrideActive {
            lidOverrideActive = false
            Task { [lid] in
                do {
                    try await lid?.restoreLidSleep()
                } catch {
                    await MainActor.run {
                        self.lastError = "Couldn't restore normal sleep. "
                            + "Run: sudo pmset -a disablesleep 0"
                    }
                }
            }
        }
        preventer.end()

        state = .idle
        totalDuration = 0
        announce(reason)
        refresh()
        return true
    }

    public func extend(by interval: TimeInterval) {
        guard case .running(let until, let options) = state else { return }
        totalDuration += interval
        state = .running(until: until.addingTimeInterval(interval), options: options)
        refresh()
    }

    /// Drives the countdown. Exposed so tests can step it without a real timer.
    public func tick() {
        if case .running(let until, _) = state, now() >= until {
            stop(reason: .expired)
            return
        }
        checkBattery()
        refresh()
    }

    // MARK: - Battery floor

    /// Checked every 15 ticks rather than every tick — charge doesn't move that fast
    /// and IOPS snapshots aren't free.
    private func checkBattery() {
        guard state.isActive else { return }
        ticksSinceBatteryCheck += 1
        guard ticksSinceBatteryCheck >= 15 else { return }
        ticksSinceBatteryCheck = 0
        evaluateBattery()
    }

    /// Split out so tests can drive it directly.
    public func evaluateBattery(_ override: BatteryState? = nil) {
        guard state.isActive, let battery = override ?? Battery.current() else { return }

        if !battery.isCharging && battery.percent < batteryFloor {
            stop(reason: .batteryFloor(battery.percent))
            return
        }
        if !batteryWarned,
           let minutes = Battery.minutesUntilFloor(battery, floor: batteryFloor),
           minutes <= 10 {
            batteryWarned = true
            Notifier.post(
                title: "Awake will stop soon",
                body: "Battery is near your \(batteryFloor)% floor — the session ends in "
                    + "about \(minutes) minute\(minutes == 1 ? "" : "s")."
            )
        }
    }

    // MARK: - Internals

    private func announce(_ reason: SessionEnd) {
        switch reason {
        case .expired:
            guard notifyOnExpiry else { return }
            Notifier.post(title: "Awake finished", body: "Your Mac can sleep normally again.")
        case .batteryFloor(let percent):
            lastError = "Battery dropped to \(percent)%, so the session was ended."
            Notifier.post(
                title: "Awake stopped",
                body: "Battery fell below your \(batteryFloor)% floor. Normal sleep is back on."
            )
        case .failed(let message):
            lastError = message
        case .manual:
            break
        }
    }

    private func startTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // .common so the countdown keeps running while the popover is tracked.
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func refresh() {
        switch state {
        case .idle:
            remaining = 0
            setLabel("")
        case .running(let until, _):
            remaining = max(0, until.timeIntervalSince(now()))
            setLabel(TimeFormat.menuBar(remaining: remaining))
        case .indefinite:
            remaining = 0
            setLabel("")  // symbol only
        }
    }

    private func setLabel(_ new: String) {
        if menuBarLabel != new { menuBarLabel = new }
    }

    private func reassertAfterWake() {
        guard state.isActive, let options = state.options else { return }
        // Assertions don't always survive a sleep/wake cycle; rebuild them.
        do {
            try preventer.begin(keepDisplayAwake: options.keepDisplayAwake)
        } catch {
            stop(reason: .failed(error.localizedDescription))
        }
        tick()
    }
}
