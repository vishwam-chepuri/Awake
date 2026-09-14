import Foundation

public enum TimeFormat {
    /// Compact label shown beside the menu bar symbol.
    /// `>= 1h` -> `1:45`, `1–59m` -> `45m`, `< 1m` -> `42s`.
    public static func menuBar(remaining: TimeInterval) -> String {
        let s = max(0, Int(remaining))
        if s >= 3600 { return "\(s / 3600):\(String(format: "%02d", (s % 3600) / 60))" }
        if s >= 60 { return "\(s / 60)m" }
        return "\(s)s"
    }

    /// Large readout inside the progress ring: `1:05:32` or `45:12`.
    public static func countdown(remaining: TimeInterval) -> String {
        let s = max(0, Int(remaining))
        let (h, m, sec) = (s / 3600, (s % 3600) / 60, s % 60)
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, sec)
            : String(format: "%d:%02d", m, sec)
    }

    /// "until 6:42 PM"
    public static func endTime(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    /// `1:50` / `0:45` — clock-style readout for the duration dial.
    public static func countdownStyle(minutes: Int) -> String {
        String(format: "%d:%02d", minutes / 60, minutes % 60)
    }

    /// Button/label text for a preset duration.
    public static func duration(_ seconds: TimeInterval) -> String {
        let m = Int(seconds) / 60
        if m % 60 == 0 && m >= 60 { return "\(m / 60)h" }
        if m >= 60 { return "\(m / 60)h \(m % 60)m" }
        return "\(m)m"
    }
}
