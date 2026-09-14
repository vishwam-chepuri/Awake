import Foundation
import SwiftUI

/// One colour idea for the whole app: a time of day maps to a colour on the arc from
/// night indigo through dawn amber, midday sky, sunset coral and dusk pink, back to night.
///
/// Everything tinted by it — dial, ring, chips, Start button — is therefore answering
/// "when does this end?". Colour is never the *only* signal: the end time is always
/// present as text, so nothing is lost if you can't distinguish the hues.
public struct DayColor: Equatable, Sendable {
    public let red, green, blue: Double

    public init(_ red: Double, _ green: Double, _ blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    public var color: Color { Color(red: red, green: green, blue: blue) }

    /// WCAG relative luminance (sRGB linearised).
    public var luminance: Double {
        func linear(_ c: Double) -> Double {
            c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// Black or white label text, whichever actually contrasts better. Some of these
    /// hues (midday gold) are far too light for white text.
    public var ink: Color {
        let onWhite = 1.05 / (luminance + 0.05)
        let onBlack = (luminance + 0.05) / 0.05
        return onBlack > onWhite ? .black : .white
    }

    /// Pulled toward its own grey. Full-saturation hues read as garish against a
    /// near-black panel, so the UI uses the muted form and keeps the stops pure.
    public func desaturated(by amount: Double) -> DayColor {
        let grey = 0.299 * red + 0.587 * green + 0.114 * blue
        return DayColor(
            red + (grey - red) * amount,
            green + (grey - green) * amount,
            blue + (grey - blue) * amount
        )
    }

    public var muted: DayColor { desaturated(by: 0.34) }

    /// Scaled toward black. On a near-black panel a full-strength fill outshines the
    /// ring; dimming the button keeps the ring the brightest thing in view.
    public func dimmed(_ factor: Double) -> DayColor {
        DayColor(red * factor, green * factor, blue * factor)
    }

    public func mixed(with other: DayColor, amount t: Double) -> DayColor {
        DayColor(
            red + (other.red - red) * t,
            green + (other.green - green) * t,
            blue + (other.blue - blue) * t
        )
    }
}

public enum DayPalette {
    /// Keyed to the hour. The 24h entry repeats the 0h one so midnight wraps smoothly.
    ///
    /// The pale stops at 11:00 and 17:30 are deliberate. Interpolating straight from
    /// morning gold to midday blue in RGB passes through a desaturated grey-green;
    /// routing via a light, low-saturation colour keeps the whole arc luminous.
    static let stops: [(hour: Double, color: DayColor)] = [
        (0, DayColor(0.29, 0.33, 0.75)),      // deep night indigo
        (4.5, DayColor(0.47, 0.36, 0.82)),    // pre-dawn violet
        (6.5, DayColor(1.00, 0.62, 0.45)),    // sunrise coral-amber
        (8.5, DayColor(1.00, 0.80, 0.38)),    // morning gold
        (11, DayColor(0.78, 0.88, 0.97)),     // late-morning pale sky
        (13, DayColor(0.26, 0.72, 0.96)),     // midday sky
        (16, DayColor(0.18, 0.78, 0.82)),     // afternoon teal
        (17.5, DayColor(0.76, 0.86, 0.72)),   // pale golden-hour turn
        (18.75, DayColor(1.00, 0.72, 0.40)),  // golden hour amber
        (20, DayColor(1.00, 0.45, 0.42)),     // sunset coral
        (21.5, DayColor(0.85, 0.34, 0.66)),   // dusk pink
        (22.75, DayColor(0.55, 0.33, 0.82)),  // late violet
        (24, DayColor(0.29, 0.33, 0.75)),     // wraps to midnight
    ]

    public static func dayColor(at date: Date, calendar: Calendar = .current) -> DayColor {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let hour = Double(parts.hour ?? 0) + Double(parts.minute ?? 0) / 60
        return dayColor(hour: hour)
    }

    public static func dayColor(hour rawHour: Double) -> DayColor {
        let hour = rawHour.truncatingRemainder(dividingBy: 24).magnitude
        guard let upper = stops.firstIndex(where: { $0.hour >= hour }) else {
            return stops[stops.count - 1].color
        }
        guard upper > 0 else { return stops[0].color }

        let a = stops[upper - 1]
        let b = stops[upper]
        let span = b.hour - a.hour
        let t = span > 0 ? (hour - a.hour) / span : 0
        return a.color.mixed(with: b.color, amount: t)
    }

    public static func color(at date: Date) -> Color { dayColor(at: date).color }
}
