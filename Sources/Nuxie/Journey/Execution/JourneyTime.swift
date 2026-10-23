import Foundation

enum JourneyTime {
    static func milliseconds(_ date: Date) -> Int64? {
        let value = date.timeIntervalSince1970 * 1_000
        guard value.isFinite,
              value >= Double(Int64.min),
              value < Double(Int64.max) else { return nil }
        // SQL cursor clocks use the nearest millisecond. Recovering an integer
        // through Date must not lose a millisecond to binary representation.
        return Int64(value.rounded(.toNearestOrAwayFromZero))
    }

    static func date(_ milliseconds: Int64) -> Date {
        Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
    }
}
