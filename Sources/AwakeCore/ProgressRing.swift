import SwiftUI

struct ProgressRing: View {
    var progress: Double
    /// Sweeps from the colour of "now" to the colour of the end time.
    var from: Color = .accentColor
    var to: Color = .accentColor
    /// Indefinite sessions have no progress to show, so the ring turns slowly instead.
    var spinning = false
    var reduceMotion = false
    var lineWidth: CGFloat = 8

    @Environment(\.colorScheme) private var colorScheme
    @State private var spin = 0.0

    /// Recessed on dark (the reference look), barely-there on light.
    var track: Color { colorScheme == .dark ? .black.opacity(0.45) : .black.opacity(0.07) }

    var body: some View {
        ZStack {
            Circle()
                .stroke(track, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            Circle()
                .trim(from: 0, to: max(0.0001, progress))
                .stroke(
                    AngularGradient(
                        colors: [from, to],
                        center: .center,
                        startAngle: .degrees(0),
                        endAngle: .degrees(360 * max(0.0001, progress))
                    ),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90 + spin))
                .shadow(color: to.opacity(0.3), radius: 5)
        }
        .onAppear {
            guard spinning, !reduceMotion else { return }
            withAnimation(.linear(duration: 8).repeatForever(autoreverses: false)) { spin = 360 }
        }
    }
}

/// Scale + fill feedback on hover and press, spring-animated.
struct LiftButtonStyle: ButtonStyle {
    var prominent = false
    /// Background colour. Solid when prominent, a soft wash otherwise.
    var fill: Color?
    /// Label colour. Defaults to white on a prominent fill, primary on a wash.
    var ink: Color?
    var padding: CGFloat = 7
    /// False for buttons that should hug their label instead of filling the row.
    var stretch = true
    var motion: Motion

    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(maxWidth: stretch ? .infinity : nil)
            .padding(.vertical, padding)
            .padding(.horizontal, stretch ? 0 : 8)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    // Explicit colours, never `.quaternary`: hierarchical styles derive
                    // from the foreground, so a red label used to tint the fill pink.
                    .fill(background)
                    // A low-opacity wash over a dark background reads as muddy olive;
                    // the border carries the hue at full strength so it stays legible.
                    .overlay {
                        if let fill, !prominent {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(fill.opacity(0.55), lineWidth: 1)
                        }
                    }
                    .opacity(configuration.isPressed ? 0.7 : (hovering ? 1 : 0.85))
            }
            .foregroundStyle(ink ?? (prominent ? .white : .primary))
            .scaleEffect(configuration.isPressed ? 0.95 : (hovering ? 1.03 : 1))
            .animation(motion.spring, value: hovering)
            .animation(motion.snappy, value: configuration.isPressed)
            .onHover { hovering = $0 }
    }

    private var background: Color {
        if prominent { return fill ?? .accentColor }
        return fill?.opacity(0.28) ?? Color.primary.opacity(0.08)
    }
}

/// Central place to honour Reduce Motion — every animation in the app routes through this.
struct Motion {
    let reduced: Bool

    var spring: Animation? { reduced ? nil : .spring(response: 0.36, dampingFraction: 0.8) }
    var snappy: Animation? { reduced ? nil : .snappy(duration: 0.26) }
    /// Matches the 1s tick so the ring sweeps continuously instead of stepping.
    var sweep: Animation? { reduced ? nil : .linear(duration: 1) }
    var transition: AnyTransition {
        reduced ? .opacity : .opacity.combined(with: .scale(scale: 0.96))
    }
}
