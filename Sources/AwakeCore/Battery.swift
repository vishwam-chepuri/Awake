import Foundation
import IOKit.ps

public struct BatteryState: Equatable, Sendable {
    public let percent: Int
    public let isCharging: Bool
    /// Minutes until empty as reported by IOKit, or nil while it's still estimating
    /// (it returns -1 for "unknown", typically right after a power source change).
    public let minutesToEmpty: Int?

    public init(percent: Int, isCharging: Bool, minutesToEmpty: Int?) {
        self.percent = percent
        self.isCharging = isCharging
        self.minutesToEmpty = minutesToEmpty
    }
}

public enum Battery {
    /// nil on a desktop Mac with no battery — callers must treat that as
    /// "battery floor does not apply", not as "battery is flat".
    public static func current() -> BatteryState? {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }

        for source in sources {
            guard let info = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue()
                as? [String: Any],
                let current = info[kIOPSCurrentCapacityKey] as? Int,
                let max = info[kIOPSMaxCapacityKey] as? Int, max > 0
            else { continue }

            let charging = (info[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            let raw = info[kIOPSTimeToEmptyKey] as? Int
            return BatteryState(
                percent: Int((Double(current) / Double(max) * 100).rounded()),
                isCharging: charging,
                minutesToEmpty: (raw ?? -1) > 0 ? raw : nil
            )
        }
        return nil
    }

    /// Minutes until the charge reaches `floor`, assuming the current drain rate
    /// holds. nil when charging, already below the floor, or no estimate yet.
    ///
    /// Linear extrapolation: `minutesToEmpty` covers percent -> 0, so the share of
    /// that spent getting to the floor is proportional to the charge above it.
    public static func minutesUntilFloor(_ state: BatteryState, floor: Int) -> Int? {
        guard !state.isCharging,
              let toEmpty = state.minutesToEmpty,
              state.percent > floor
        else { return nil }
        let above = Double(state.percent - floor) / Double(state.percent)
        return Int((Double(toEmpty) * above).rounded())
    }
}
