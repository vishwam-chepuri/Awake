import AppKit
import SwiftUI

/// Drag around the ring to set a duration. One sweep covers the whole 5m–12h range
/// on a curve, so every value is reachable without winding round more than once —
/// and coming back down from 7h is half a turn, not six and a half.
struct DurationDial: View {
    @Binding var minutes: Int
    var motion: Motion
    /// Passed in rather than read here so a TimelineView can keep "ends at" current.
    var now: Date = Date()
    var range: ClosedRange<Int> = DialMath.minMinutes...DialMath.maxMinutes

    @Environment(\.colorScheme) private var colorScheme

    /// Unsnapped position carried across drag samples so the snap doesn't fight the
    /// drag. Held as a fraction of the sweep, since that's what the angle maps to.
    @State private var rawFraction: Double?
    @State private var lastAngle: Double?

    private static let lineWidth: CGFloat = 8

    private static let side: CGFloat = 104

    /// Radius of the stroked path itself. `Circle().stroke()` centres the stroke on the
    /// shape's edge without insetting, so both circles are inset by half the line width
    /// to bring the path here — and the knob orbits this exact radius so it sits *on*
    /// the arc rather than inside it.
    private static var pathRadius: CGFloat { side / 2 - lineWidth / 2 }

    var body: some View {
        let radius = Self.pathRadius

        return Group {
            ZStack {
                ticks(radius: radius)

                Circle()
                    .inset(by: Self.lineWidth / 2)
                    .stroke(colorScheme == .dark ? Color.black.opacity(0.45) : Color.black.opacity(0.07),
                            style: StrokeStyle(lineWidth: Self.lineWidth, lineCap: .round))

                Circle()
                    .inset(by: Self.lineWidth / 2)
                    .trim(from: 0, to: turnFraction)
                    .stroke(
                        // Sweeps from "now" to "then", so the arc is literally the
                        // stretch of day the session covers. Gradient ends where the
                        // trim ends, so the full range is visible on the drawn arc.
                        AngularGradient(
                            colors: [nowColor.muted.color, endColor.muted.color],
                            center: .center,
                            startAngle: .degrees(0),
                            endAngle: .degrees(360 * turnFraction)
                        ),
                        style: StrokeStyle(lineWidth: Self.lineWidth, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .shadow(color: endColor.muted.color.opacity(0.3), radius: 5)

                knob(radius: radius)
                readout
            }
            .frame(width: Self.side, height: Self.side)
            .contentShape(Circle())
            .gesture(drag(center: CGPoint(x: Self.side / 2, y: Self.side / 2)))
        }
        .focusable()
        .onKeyPress(.upArrow) { nudge(+1); return .handled }
        .onKeyPress(.rightArrow) { nudge(+1); return .handled }
        .onKeyPress(.downArrow) { nudge(-1); return .handled }
        .onKeyPress(.leftArrow) { nudge(-1); return .handled }
        .accessibilityElement()
        .accessibilityLabel("Duration")
        .accessibilityValue(TimeFormat.duration(TimeInterval(minutes) * 60))
        .accessibilityAdjustableAction { direction in
            nudge(direction == .increment ? +1 : -1)
        }
    }

    // MARK: - Pieces

    private var readout: some View {
        VStack(spacing: 1) {
            Text(TimeFormat.countdownStyle(minutes: minutes))
                .font(.system(size: 22, weight: .medium, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(motion.snappy, value: minutes)
            Text("ends \(TimeFormat.endTime(endsAt))")
                .font(.caption2.weight(.medium))
                .foregroundStyle(endColor.muted.color)
        }
    }

    /// Ticks mark the preset durations at their real positions on the sweep, so the
    /// chips and the ring agree about where "1h" is.
    private static let tickMinutes: [Double] = [15, 30, 60, 120, 240, 480]

    private func ticks(radius: CGFloat) -> some View {
        ForEach(Self.tickMinutes, id: \.self) { m in
            Capsule()
                .fill(Color.primary.opacity(0.16))
                .frame(width: 1.5, height: 3)
                .offset(y: -(radius - Self.lineWidth / 2 - 4))
                .rotationEffect(.degrees(DialMath.fraction(forMinutes: m) * 360))
        }
    }

    private func knob(radius: CGFloat) -> some View {
        let radians = (turnFraction * 360 - 90) * .pi / 180
        return Circle()
            .fill(.white)
            .overlay(Circle().stroke(endColor.muted.color, lineWidth: 2.5))
            .frame(width: 15, height: 15)
            .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
            .offset(x: cos(radians) * radius, y: sin(radians) * radius)
            .animation(motion.snappy, value: minutes)
    }

    var endsAt: Date { now.addingTimeInterval(TimeInterval(minutes) * 60) }
    private var nowColor: DayColor { DayPalette.dayColor(at: now) }
    private var endColor: DayColor { DayPalette.dayColor(at: endsAt) }

    /// How far round the sweep the current value sits.
    private var turnFraction: Double {
        DialMath.fraction(forMinutes: Double(minutes))
    }

    // MARK: - Input

    private func drag(center: CGPoint) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let dx = value.location.x - center.x
                let dy = value.location.y - center.y
                guard dx != 0 || dy != 0 else { return }

                var degrees = atan2(dy, dx) * 180 / .pi + 90
                if degrees < 0 { degrees += 360 }
                defer { lastAngle = degrees }

                guard let last = lastAngle else { return }
                let delta = DialMath.delta(from: last, to: degrees)
                // One sweep spans the whole range, so the angle moves a *fraction*
                // and the fraction is mapped to minutes — not the other way round.
                let next = ((rawFraction ?? turnFraction) + delta / 360).clamped(to: 0...1)
                rawFraction = next
                apply(DialMath.snapMinutes(DialMath.minutes(atFraction: next), fine: fineStep))
            }
            .onEnded { _ in
                rawFraction = nil
                lastAngle = nil
            }
    }

    private func nudge(_ direction: Int) {
        // Look half a step in the travel direction so stepping *down* across a
        // boundary picks the finer grid rather than the coarser one.
        let probe = Double(minutes) + (direction > 0 ? 0.5 : -0.5)
        let s = DialMath.step(forMinutes: probe, fine: fineStep)
        apply((minutes + direction * s).clamped(to: range))
        rawFraction = nil
    }

    /// Hold Option for finer steps than the current range's default.
    private var fineStep: Bool {
        NSEvent.modifierFlags.contains(.option)
    }

    private func apply(_ new: Int) {
        let clamped = new.clamped(to: range)
        guard clamped != minutes else { return }
        minutes = clamped
        // Trackpad detent on each snap — the thing that makes a dial feel physical.
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }
}

extension Comparable {
    public func clamped(to limits: ClosedRange<Self>) -> Self {
        min(max(self, limits.lowerBound), limits.upperBound)
    }
}

/// Pure geometry behind the dial, split out so it can be checked without a gesture.
public enum DialMath {
    /// Shortest signed travel between two headings, so crossing 12 o'clock reads as a
    /// small step in the direction of travel rather than a near-full turn backwards.
    public static func delta(from: Double, to: Double) -> Double {
        var d = to - from
        if d > 180 { d -= 360 }
        if d < -180 { d += 360 }
        return d
    }

    public static func snap(_ value: Double, step: Int) -> Int {
        Int((value / Double(step)).rounded()) * step
    }

    // MARK: - Range mapping
    //
    // One sweep of the ring covers the whole 5m–12h range, so any duration is
    // reachable without winding round more than once. The mapping is piecewise
    // linear against these anchors: roughly a third of the turn buys the first
    // hour, where precision actually matters, and the last third covers 4h–12h,
    // where it doesn't.

    public static let minMinutes = 5
    public static let maxMinutes = 12 * 60

    static let anchors: [(fraction: Double, minutes: Double)] = [
        (0.00, 5),
        (0.35, 60),
        (0.65, 240),
        (1.00, 720),
    ]

    public static func minutes(atFraction raw: Double) -> Double {
        let f = raw.clamped(to: 0...1)
        guard let i = anchors.firstIndex(where: { $0.fraction >= f }), i > 0 else {
            return anchors[0].minutes
        }
        let a = anchors[i - 1], b = anchors[i]
        let span = b.fraction - a.fraction
        let t = span > 0 ? (f - a.fraction) / span : 0
        return a.minutes + (b.minutes - a.minutes) * t
    }

    public static func fraction(forMinutes raw: Double) -> Double {
        let m = raw.clamped(to: Double(minMinutes)...Double(maxMinutes))
        guard let i = anchors.firstIndex(where: { $0.minutes >= m }), i > 0 else {
            return anchors[0].fraction
        }
        let a = anchors[i - 1], b = anchors[i]
        let span = b.minutes - a.minutes
        let t = span > 0 ? (m - a.minutes) / span : 0
        return a.fraction + (b.fraction - a.fraction) * t
    }

    /// Coarser steps at longer durations — nobody sets 7 hours to the minute. Keeps
    /// each step roughly the same number of degrees right across the sweep.
    public static func step(forMinutes m: Double, fine: Bool) -> Int {
        switch m {
        case ..<60: fine ? 1 : 5
        case ..<240: fine ? 5 : 15
        default: fine ? 10 : 30
        }
    }

    public static func snapMinutes(_ value: Double, fine: Bool) -> Int {
        let s = step(forMinutes: value, fine: fine)
        let snapped = Int((value / Double(s)).rounded()) * s
        return snapped.clamped(to: minMinutes...maxMinutes)
    }
}
