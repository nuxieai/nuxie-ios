import Foundation

/// Pure calendar math for the `time_window` journey action.
///
/// Data-in/data-out: dates + window config in, a decision out. No clocks and
/// no side effects — the runner supplies `now` and applies the decision. This
/// shape is the portable spec for other SDK platforms.
enum TimeWindowMath {
    /// Sentinel timezone identifier meaning "use the device's current timezone".
    static let currentDeviceTimezoneToken = "__current_device__"

    enum Decision: Equatable {
        /// Start/end times were unparseable; skip the window node (continue the
        /// sequence without running success actions).
        case malformed
        /// `now` is inside the window; run the success actions.
        case inWindow
        /// Outside the window; pause until the given instant.
        case pause(until: Date)
    }

    static func resolveTimezone(_ rawTimezone: String, current: TimeZone = .current) -> TimeZone {
        if rawTimezone == currentDeviceTimezoneToken {
            return current
        }
        return TimeZone(identifier: rawTimezone) ?? current
    }

    static func evaluate(
        now: Date,
        startTime: String,
        endTime: String,
        daysOfWeek: [Int]?,
        timezone: TimeZone
    ) -> Decision {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timezone

        guard let startHM = parseTime(startTime),
              let endHM = parseTime(endTime),
              let sh = startHM.hour, let sm = startHM.minute,
              let eh = endHM.hour, let em = endHM.minute
        else {
            return .malformed
        }

        let weekday = cal.component(.weekday, from: now)
        if let days = daysOfWeek, !days.isEmpty, !days.contains(weekday) {
            return .pause(until: nextValidDay(from: now, validDays: days, timezone: timezone))
        }

        let currentHM = cal.dateComponents([.hour, .minute], from: now)
        let curMin = (currentHM.hour ?? 0) * 60 + (currentHM.minute ?? 0)
        let startMin = sh * 60 + sm
        let endMin = eh * 60 + em

        if startMin == endMin {
            return .inWindow
        }

        let inWindow =
            (startMin <= endMin)
            ? (curMin >= startMin && curMin < endMin)
            : (curMin >= startMin || curMin < endMin)

        if inWindow {
            return .inWindow
        }

        return .pause(until: nextWindowOpen(
            from: now,
            startTime: startTime,
            timezone: timezone,
            validDays: daysOfWeek
        ))
    }

    static func parseTime(_ timeString: String) -> DateComponents? {
        let parts = timeString.split(separator: ":")
        guard parts.count == 2,
              let hour = Int(parts[0]),
              let minute = Int(parts[1])
        else { return nil }

        var components = DateComponents()
        components.hour = hour
        components.minute = minute
        return components
    }

    static func nextValidDay(from date: Date, validDays: [Int], timezone: TimeZone) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timezone

        for i in 1...7 {
            guard let nextDate = cal.date(byAdding: .day, value: i, to: date) else { continue }
            let weekday = cal.component(.weekday, from: nextDate)
            if validDays.contains(weekday) {
                var comps = cal.dateComponents([.year, .month, .day], from: nextDate)
                comps.hour = 0
                comps.minute = 0
                comps.second = 0
                comps.timeZone = timezone
                return cal.date(from: comps) ?? nextDate
            }
        }

        return date
    }

    static func nextWindowOpen(
        from date: Date,
        startTime: String,
        timezone: TimeZone,
        validDays: [Int]?
    ) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timezone

        guard let startHM = parseTime(startTime),
              let sh = startHM.hour, let sm = startHM.minute
        else { return date }

        var today = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        today.hour = sh
        today.minute = sm
        today.second = 0
        today.timeZone = timezone

        var nextOpen = cal.date(from: today) ?? date

        if nextOpen <= date {
            nextOpen = cal.date(byAdding: .day, value: 1, to: nextOpen) ?? nextOpen
        }

        if let days = validDays, !days.isEmpty {
            while true {
                let wd = cal.component(.weekday, from: nextOpen)
                if days.contains(wd) { break }
                nextOpen = cal.date(byAdding: .day, value: 1, to: nextOpen) ?? nextOpen
            }
        }

        return nextOpen
    }
}
