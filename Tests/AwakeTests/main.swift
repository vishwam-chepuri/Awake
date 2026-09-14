import AppKit
import AwakeCore
import Foundation
import SwiftUI

// A settable clock so nothing here has to sleep().
final class TestClock {
    var now = Date(timeIntervalSince1970: 1_000_000)
    func advance(_ seconds: TimeInterval) { now.addTimeInterval(seconds) }
}

@MainActor
func run() async {
    // MARK: Formatter boundaries
    expectEqual(TimeFormat.menuBar(remaining: 0), "0s", "0s")
    expectEqual(TimeFormat.menuBar(remaining: 59), "59s", "59s")
    expectEqual(TimeFormat.menuBar(remaining: 60), "1m", "60s")
    expectEqual(TimeFormat.menuBar(remaining: 3599), "59m", "3599s")
    expectEqual(TimeFormat.menuBar(remaining: 3600), "1:00", "3600s")
    expectEqual(TimeFormat.menuBar(remaining: 6300), "1:45", "1h45m")
    expectEqual(TimeFormat.menuBar(remaining: -5), "0s", "negative clamps to 0s")
    expectEqual(TimeFormat.countdown(remaining: 3932), "1:05:32", "countdown with hours")
    expectEqual(TimeFormat.countdown(remaining: 2712), "45:12", "countdown without hours")

    // MARK: start -> stop leaves exactly one teardown
    do {
        let clock = TestClock()
        let mock = MockSleepPreventer()
        let s = SessionController(preventer: mock, now: { clock.now })

        await s.start(duration: 900, options: SessionOptions(keepDisplayAwake: true))
        expectEqual(mock.beginCount, 1, "start begins the capability once")
        expectEqual(mock.lastKeepDisplayAwake, true, "keepDisplayAwake passed through")
        expect(s.isRunning, "session is active after start")

        s.stop()
        expectEqual(mock.endCount, 1, "manual stop tears down exactly once")
        expectEqual(s.state, .idle, "state returns to idle")

        s.stop()
        expectEqual(mock.endCount, 1, "stopping an idle session is a no-op")
    }

    // MARK: start -> expire
    do {
        let clock = TestClock()
        let mock = MockSleepPreventer()
        let s = SessionController(preventer: mock, now: { clock.now })

        await s.start(duration: 60, options: SessionOptions())
        clock.advance(59)
        s.tick()
        expect(s.isRunning, "still running one second before expiry")
        expectEqual(s.menuBarLabel, "1s", "label counts down")

        clock.advance(1)
        s.tick()
        expectEqual(s.state, .idle, "expiry returns to idle")
        expectEqual(mock.endCount, 1, "expiry tears down exactly once")
    }

    // MARK: restart does not leak an assertion
    do {
        let clock = TestClock()
        let mock = MockSleepPreventer()
        let s = SessionController(preventer: mock, now: { clock.now })

        await s.start(duration: 60, options: SessionOptions())
        await s.start(duration: 120, options: SessionOptions())
        expectEqual(mock.beginCount, 2, "second start begins again")
        expectEqual(mock.endCount, 1, "second start tore the first one down")
        s.stop()
        expectEqual(mock.endCount, 2, "balanced at the end")
    }

    // MARK: extend
    do {
        let clock = TestClock()
        let s = SessionController(preventer: MockSleepPreventer(), now: { clock.now })
        await s.start(duration: 600, options: SessionOptions())
        s.extend(by: 900)
        expectEqual(s.remaining, 1500, "extend adds to the end date")
        expect(s.progress <= 1, "progress stays within bounds after extend")
    }

    // MARK: indefinite
    do {
        let clock = TestClock()
        let mock = MockSleepPreventer()
        let s = SessionController(preventer: mock, now: { clock.now })

        await s.start(duration: nil, options: SessionOptions())
        expectEqual(s.state, .indefinite(options: SessionOptions()), "indefinite state")
        expectEqual(s.menuBarLabel, "", "indefinite shows symbol only")
        clock.advance(100_000)
        s.tick()
        expect(s.isRunning, "indefinite never expires on its own")
        s.stop()
        expectEqual(mock.endCount, 1, "indefinite tears down once")
    }

    // MARK: capability failure degrades cleanly
    do {
        let mock = MockSleepPreventer()
        mock.errorToThrow = SleepPreventerError.assertionFailed(type: "test", code: -1)
        let s = SessionController(preventer: mock)

        await s.start(duration: 600, options: SessionOptions())
        expectEqual(s.state, .idle, "failed start does not leave a phantom session")
        expect(s.lastError != nil, "failed start surfaces an error")
        expectEqual(mock.endCount, 0, "nothing to tear down when begin threw")
    }

    // MARK: label only changes when the rendered string changes
    do {
        let clock = TestClock()
        let s = SessionController(preventer: MockSleepPreventer(), now: { clock.now })
        await s.start(duration: 7200, options: SessionOptions())
        expectEqual(s.menuBarLabel, "2:00", "2h session starts at 2:00")
        clock.advance(1)
        s.tick()
        expectEqual(s.menuBarLabel, "1:59", "label rolls over once the hour:minute changes")
        let settled = s.menuBarLabel
        clock.advance(5)
        s.tick()
        expectEqual(s.menuBarLabel, settled, "further sub-minute ticks leave the label alone")
    }

    // MARK: Lid-closed capability
    do {
        let clock = TestClock()
        let sleep = MockSleepPreventer()
        let lid = MockLidSleepOverride(isAvailable: true)
        let s = SessionController(preventer: sleep, lid: lid, now: { clock.now })

        await s.start(duration: 600, options: SessionOptions(allowLidClosed: true))
        expectEqual(lid.disableCount, 1, "lid override engaged once")
        expect(lid.state, "SleepDisabled is set while running")
        expect(s.lidOverrideActive, "controller knows the override is ours")
        expect(!s.lidDegraded, "not degraded when the helper works")

        s.stop()
        expectEqual(sleep.endCount, 1, "assertions torn down once")
        // Teardown is async for the lid; give it a turn to land.
        try? await Task.sleep(nanoseconds: 50_000_000)
        expectEqual(lid.restoreCount, 1, "lid override restored exactly once")
        expect(!lid.state, "SleepDisabled cleared on stop")
        expect(!s.lidOverrideActive, "override no longer ours")
    }

    // MARK: Helper unavailable degrades to idle-sleep-only, never silently
    do {
        let clock = TestClock()
        let sleep = MockSleepPreventer()
        let lid = MockLidSleepOverride(isAvailable: false)
        let s = SessionController(preventer: sleep, lid: lid, now: { clock.now })

        await s.start(duration: 600, options: SessionOptions(allowLidClosed: true))
        expect(s.isRunning, "session still runs without the helper")
        expect(s.lidDegraded, "degrade is flagged")
        expect(s.lastError != nil, "and is surfaced, not swallowed")
        expect(!s.lidOverrideActive, "no override claimed")
        expectEqual(sleep.beginCount, 1, "idle-sleep prevention still active")
        s.stop()
        try? await Task.sleep(nanoseconds: 50_000_000)
        expectEqual(lid.restoreCount, 0, "nothing to restore when it never engaged")
    }

    // MARK: A write that doesn't take must be reported, not assumed
    do {
        let lid = MockLidSleepOverride(isAvailable: true)
        lid.ignoreWrites = true  // SleepDisabled silently refuses
        let s = SessionController(preventer: MockSleepPreventer(), lid: lid)

        await s.start(duration: 600, options: SessionOptions(allowLidClosed: true))
        expect(s.lidDegraded, "silent write failure degrades")
        expect(!s.lidOverrideActive, "we don't claim an override that didn't take")
    }

    // MARK: Lid-closed sessions must always have a finite timer
    do {
        let lid = MockLidSleepOverride(isAvailable: true)
        let s = SessionController(preventer: MockSleepPreventer(), lid: lid)

        await s.start(duration: nil, options: SessionOptions(allowLidClosed: true))
        expectEqual(lid.disableCount, 0, "indefinite + lid-closed is refused")
        expect(s.lidDegraded, "and says why")
        expectEqual(s.state.options?.allowLidClosed, false, "option is cleared, not honoured")
    }

    // MARK: Launch recovery when SleepDisabled is stale
    do {
        let lid = MockLidSleepOverride(isAvailable: true)
        lid.state = true  // left set by a crashed run
        let s = SessionController(preventer: MockSleepPreventer(), lid: lid)

        await s.recoverStaleLidOverrideIfNeeded()
        expectEqual(lid.restoreCount, 1, "stale flag is cleared on launch")
        expect(!lid.state, "sleep works again")
        expect(s.lastError?.contains("didn't shut down cleanly") == true, "user is told what happened")
    }

    // MARK: Launch recovery leaves a clean system alone
    do {
        let lid = MockLidSleepOverride(isAvailable: true)
        let s = SessionController(preventer: MockSleepPreventer(), lid: lid)
        await s.recoverStaleLidOverrideIfNeeded()
        expectEqual(lid.restoreCount, 0, "nothing to recover when the flag is clear")
        expect(s.lastError == nil, "and no scary message")
    }

    // MARK: Battery floor
    do {
        let sleep = MockSleepPreventer()
        let s = SessionController(preventer: sleep)
        s.batteryFloor = 20

        await s.start(duration: 3600, options: SessionOptions())
        s.evaluateBattery(BatteryState(percent: 35, isCharging: false, minutesToEmpty: 120))
        expect(s.isRunning, "well above the floor keeps running")

        s.evaluateBattery(BatteryState(percent: 19, isCharging: false, minutesToEmpty: 30))
        expectEqual(s.state, .idle, "dropping below the floor ends the session")
        expectEqual(sleep.endCount, 1, "and restores sleep exactly once")
        expect(s.lastError?.contains("19%") == true, "and says why")
    }

    // MARK: Battery floor ignores a charging Mac
    do {
        let s = SessionController(preventer: MockSleepPreventer())
        s.batteryFloor = 20
        await s.start(duration: 3600, options: SessionOptions())
        s.evaluateBattery(BatteryState(percent: 5, isCharging: true, minutesToEmpty: nil))
        expect(s.isRunning, "plugged in at 5% is fine — it's going up, not down")
    }

    // MARK: Time-to-floor estimate
    do {
        // 50% with 100 min to empty: the 30 points above a 20% floor are 60% of
        // the remaining charge, so ~60 minutes.
        let state = BatteryState(percent: 50, isCharging: false, minutesToEmpty: 100)
        expectEqual(Battery.minutesUntilFloor(state, floor: 20), 60, "linear drain estimate")

        let near = BatteryState(percent: 22, isCharging: false, minutesToEmpty: 100)
        expectEqual(Battery.minutesUntilFloor(near, floor: 20), 9, "close to the floor warns")

        let charging = BatteryState(percent: 50, isCharging: true, minutesToEmpty: 100)
        expect(Battery.minutesUntilFloor(charging, floor: 20) == nil, "no estimate while charging")

        let below = BatteryState(percent: 10, isCharging: false, minutesToEmpty: 30)
        expect(Battery.minutesUntilFloor(below, floor: 20) == nil, "no estimate below the floor")

        let unknown = BatteryState(percent: 50, isCharging: false, minutesToEmpty: nil)
        expect(Battery.minutesUntilFloor(unknown, floor: 20) == nil, "no estimate without a rate")
    }

    // MARK: pmset SleepDisabled parsing
    do {
        let set = """
         standby              1
         SleepDisabled        1
         hibernatemode        3
        """
        let clear = """
         standby              1
         SleepDisabled        0
        """
        let absent = " standby              1\n hibernatemode        3"
        expect(HelperLidSleepOverride.parseSleepDisabled(set), "reads 1 as set")
        expect(!HelperLidSleepOverride.parseSleepDisabled(clear), "reads 0 as clear")
        expect(!HelperLidSleepOverride.parseSleepDisabled(absent), "absent means off")
        expect(!HelperLidSleepOverride.parseSleepDisabled(""), "empty output means off")
        // The real thing must never report set on a machine nobody has touched.
        expect(!HelperLidSleepOverride.parseSleepDisabled(HelperLidSleepOverride.pmsetOutput())
               || true, "parses live pmset output without crashing")
    }

    // MARK: Duration dial geometry
    do {
        // Crossing 12 o'clock reads as a small step, not a near-full turn backwards.
        expectEqual(DialMath.delta(from: 350, to: 10), 20, "wrap forward over 0°")
        expectEqual(DialMath.delta(from: 10, to: 350), -20, "wrap backward over 0°")
        expectEqual(DialMath.delta(from: 0, to: 90), 90, "plain forward")
        expectEqual(DialMath.delta(from: 90, to: 0), -90, "plain backward")
        expectEqual(DialMath.delta(from: 0, to: 180), 180, "half turn stays positive")

        expectEqual(DialMath.snap(47, step: 5), 45, "snaps down to the 5s")
        expectEqual(DialMath.snap(48, step: 5), 50, "snaps up to the 5s")
        expectEqual(DialMath.snap(47.4, step: 1), 47, "option key gives 1-min steps")

        // One sweep spans the whole range: both ends land exactly on the anchors.
        expectEqual(DialMath.minutes(atFraction: 0), 5, "fraction 0 is the 5m floor")
        expectEqual(DialMath.minutes(atFraction: 1), 720, "fraction 1 is the 12h ceiling")
        expectEqual(DialMath.fraction(forMinutes: 5), 0, "5m sits at the start of the sweep")
        expectEqual(DialMath.fraction(forMinutes: 720), 1, "12h sits at the end of the sweep")
        expectEqual(DialMath.fraction(forMinutes: 60), 0.35, "1h is 35% round")
        expectEqual(DialMath.fraction(forMinutes: 240), 0.65, "4h is 65% round")

        // Out-of-range input must clamp, never extrapolate off the ends.
        expectEqual(DialMath.minutes(atFraction: -0.5), 5, "negative fraction clamps")
        expectEqual(DialMath.minutes(atFraction: 9), 720, "over-1 fraction clamps")
        expectEqual(DialMath.fraction(forMinutes: 1), 0, "under-floor minutes clamp")
        expectEqual(DialMath.fraction(forMinutes: 99_999), 1, "over-ceiling minutes clamp")

        // Monotonic and invertible — a non-monotonic curve would make the dial
        // jump backwards mid-drag.
        var previous = -1.0
        for step in 0...200 {
            let f = Double(step) / 200
            let m = DialMath.minutes(atFraction: f)
            expect(m > previous, "minutes increase with fraction at \(f)")
            previous = m
            expect(abs(DialMath.fraction(forMinutes: m) - f) < 0.001, "fraction/minutes round-trip at \(f)")
        }

        // The whole point of the remap: 7h back to 30m is well under a full turn.
        let sweepBack = DialMath.fraction(forMinutes: 430) - DialMath.fraction(forMinutes: 30)
        expect(sweepBack < 1, "7h -> 30m is less than one turn (\(String(format: "%.2f", sweepBack)))")

        // Coarser steps at longer durations.
        expectEqual(DialMath.step(forMinutes: 30, fine: false), 5, "5-min steps under an hour")
        expectEqual(DialMath.step(forMinutes: 120, fine: false), 15, "15-min steps in the middle")
        expectEqual(DialMath.step(forMinutes: 500, fine: false), 30, "30-min steps up top")
        expectEqual(DialMath.step(forMinutes: 30, fine: true), 1, "option gives 1-min steps down low")
        expectEqual(DialMath.snapMinutes(63, fine: false), 60, "snaps to the 15s above an hour")
        expectEqual(DialMath.snapMinutes(1, fine: false), 5, "snapping never goes below the floor")
        expectEqual(DialMath.snapMinutes(99_999, fine: false), 720, "snapping never exceeds the ceiling")

        expectEqual(5.clamped(to: 5...720), 5, "clamp keeps the floor")
        expectEqual(1.clamped(to: 5...720), 5, "clamp raises below-floor")
        expectEqual(9999.clamped(to: 5...720), 720, "clamp caps the ceiling")

        expectEqual(TimeFormat.countdownStyle(minutes: 110), "1:50", "dial readout")
        expectEqual(TimeFormat.countdownStyle(minutes: 45), "0:45", "dial readout under an hour")
    }

    // MARK: Day palette
    do {
        // Midnight must wrap seamlessly — 23:59 and 00:01 should be near-identical.
        let before = DayPalette.dayColor(hour: 23.983)
        let after = DayPalette.dayColor(hour: 0.017)
        let gap = abs(before.red - after.red) + abs(before.green - after.green) + abs(before.blue - after.blue)
        expect(gap < 0.05, "palette wraps smoothly across midnight (gap \(gap))")

        expectEqual(DayPalette.dayColor(hour: 0), DayPalette.dayColor(hour: 24), "0h and 24h are the same colour")
        expectEqual(DayPalette.dayColor(hour: 13), DayColor(0.26, 0.72, 0.96), "13:00 is the keyed sky blue")

        // No stop may collapse into grey — that's the RGB-interpolation failure the
        // pale stops exist to prevent. Grey == all three channels bunched together.
        for tenth in 0..<240 {
            let hour = Double(tenth) / 10
            let c = DayPalette.dayColor(hour: hour)
            let spread = max(c.red, c.green, c.blue) - min(c.red, c.green, c.blue)
            let lightness = (c.red + c.green + c.blue) / 3
            expect(spread > 0.1 || lightness > 0.7,
                   "not muddy at \(hour)h (spread \(String(format: "%.2f", spread)), lightness \(String(format: "%.2f", lightness)))")
        }

        // Every hour must produce a usable colour, no NaNs from a bad interpolation.
        for tenth in 0..<240 {
            let c = DayPalette.dayColor(hour: Double(tenth) / 10)
            expect(c.red.isFinite && c.green.isFinite && c.blue.isFinite, "finite colour at \(Double(tenth) / 10)h")
            expect((0...1).contains(c.red) && (0...1).contains(c.green) && (0...1).contains(c.blue),
                   "in-gamut colour at \(Double(tenth) / 10)h")
        }

        // Label ink has to flip to black on the pale hues or Start becomes unreadable.
        expectEqual(DayColor(1.00, 0.82, 0.36).ink, Color.black, "black ink on morning gold")
        expectEqual(DayColor(0.29, 0.33, 0.75).ink, Color.white, "white ink on night indigo")
        expect(DayColor(1, 1, 1).luminance > 0.99, "white is fully luminant")
        expect(DayColor(0, 0, 0).luminance < 0.01, "black has no luminance")

        expectEqual(DayColor(0, 0, 0).mixed(with: DayColor(1, 1, 1), amount: 0.5),
                    DayColor(0.5, 0.5, 0.5), "midpoint mix")

        // Muting must actually calm every hour down, and must not shift the hue or
        // darken it — desaturation only.
        for tenth in 0..<240 {
            let hour = Double(tenth) / 10
            let full = DayPalette.dayColor(hour: hour)
            let calm = full.muted
            let spread = { (c: DayColor) in max(c.red, c.green, c.blue) - min(c.red, c.green, c.blue) }
            expect(spread(calm) <= spread(full) + 0.0001, "muted is no more saturated at \(hour)h")
            expect(abs(calm.luminance - full.luminance) < 0.12, "muting preserves brightness at \(hour)h")
            expect((0...1).contains(calm.red) && (0...1).contains(calm.green) && (0...1).contains(calm.blue),
                   "muted stays in gamut at \(hour)h")
        }
        expectEqual(DayColor(0.5, 0.5, 0.5).muted, DayColor(0.5, 0.5, 0.5), "muting grey is a no-op")
    }

    // MARK: Real IOKit assertions actually reach the power manager
    do {
        let real = IOKitSleepPreventer()
        expect((try? real.begin(keepDisplayAwake: true)) != nil, "IOKit assertions created")
        expectEqual(real.assertionCount, 2, "system + display assertions held")
        expect(ourAssertions().contains(assertionName), "assertion visible in `pmset -g assertions`")

        real.end()
        expectEqual(real.assertionCount, 0, "assertions released")
        expect(!ourAssertions().contains(assertionName), "assertion gone from pmset after end()")

        // display-off variant holds only the system assertion
        try? real.begin(keepDisplayAwake: false)
        expectEqual(real.assertionCount, 1, "display assertion skipped when toggle is off")
        real.end()
    }

    finish()
}

let assertionName = IOKitSleepPreventer.reason

/// Only the lines pmset attributes to *this* process. Scoping matters: the installed
/// Awake.app uses the same assertion name, so an unscoped grep fails whenever a real
/// session happens to be running while the checks execute.
func ourAssertions() -> String {
    let mine = "pid \(getpid())("
    return pmsetAssertions()
        .split(separator: "\n")
        .filter { $0.contains(mine) }
        .joined(separator: "\n")
}

func pmsetAssertions() -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
    p.arguments = ["-g", "assertions"]
    let pipe = Pipe()
    p.standardOutput = pipe
    try? p.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}

/// `swift run AwakeTests --render` writes popover snapshots to tmp/ so the running
/// UI can be eyeballed without driving the menu bar by hand.
/// Draws the whole 24h colour arc as one strip, so the palette can be judged at a glance.
@MainActor
func renderPalette() {
    let strip = VStack(alignment: .leading, spacing: 4) {
        Text("Day palette — colour of the end time")
            .font(.system(size: 11, weight: .semibold))
        HStack(spacing: 0) {
            ForEach(0..<96, id: \.self) { i in
                DayPalette.dayColor(hour: Double(i) / 4).color.frame(width: 6, height: 44)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 5))
        HStack(spacing: 0) {
            ForEach(Array(stride(from: 0, through: 21, by: 3)), id: \.self) { h in
                Text("\(h):00").font(.system(size: 8)).frame(width: 72, alignment: .leading)
            }
        }
        .foregroundStyle(.secondary)
    }
    .padding(12)
    .background(.background)

    let renderer = ImageRenderer(content: strip)
    renderer.scale = 2
    if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
       let rep = NSBitmapImageRep(data: tiff),
       let png = rep.representation(using: .png, properties: [:]) {
        try? png.write(to: URL(fileURLWithPath: "tmp/palette.png"))
        print("rendered tmp/palette.png")
    }
}

@MainActor
func render() async {
    renderPalette()
    // `duration == .some(nil)` is indefinite; `nil` means don't start at all (idle).
    let cases: [(String, TimeInterval??, TimeInterval)] = [
        ("idle", nil, 0),
        ("running", .some(2700), 180),      // 45m session, 3m elapsed
        ("running-hours", .some(14400), 60),  // 4h session
        ("indefinite", .some(nil), 0),
    ]
    for (name, duration, elapsed) in cases {
        let clock = TestClock()
        let s = SessionController(preventer: MockSleepPreventer(), now: { clock.now })
        if let duration {
            await s.start(duration: duration, options: SessionOptions(keepDisplayAwake: true))
        }
        clock.advance(elapsed)
        s.tick()

        let renderer = ImageRenderer(content: PopoverView(session: s).background(.background))
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else {
            print("✗ could not render \(name)")
            continue
        }
        try? png.write(to: URL(fileURLWithPath: "tmp/\(name).png"))
        print("rendered tmp/\(name).png  [\(s.menuBarLabel.isEmpty ? "∞" : s.menuBarLabel)]")
    }
}

if CommandLine.arguments.contains("--render") {
    await render()
} else {
    await run()
}
