import Foundation

/// Deterministic calendar math for Journey time windows.
/// All timezone offsets come from the verified, pinned IANA bundle.
enum TimeWindowMath {
    static let currentDeviceTimezoneToken = "__current_device__"

    enum Decision: Equatable {
        case malformed
        case unavailable
        case inWindow
        case pause(until: Date)
    }

    static func resolveTimezone(_ rawTimezone: String, current: TimeZone = .current, bundle: SignedTimezoneBundle? = .installed) -> SignedJourneyTimezone? {
        guard let bundle else { return nil }
        if rawTimezone == currentDeviceTimezoneToken {
            return try? bundle.resolveDeviceIdentifier(current.identifier)
        }
        return try? bundle.resolve(rawTimezone)
    }

    static func resolveTimezone(_ timezone: JourneyTimezone, current: TimeZone = .current, appDefault: String? = nil, bundle: SignedTimezoneBundle? = .installed) -> SignedJourneyTimezone? {
        switch timezone {
        case .device: return resolveTimezone(currentDeviceTimezoneToken, current: current, bundle: bundle)
        case .appDefault:
            guard let appDefault else { return nil }
            return resolveTimezone(appDefault, current: current, bundle: bundle)
        case .iana(let identifier): return resolveTimezone(identifier, current: current, bundle: bundle)
        }
    }

    static func evaluate(now: Date, startTime: String, endTime: String, daysOfWeek: [Int]?, timezone: SignedJourneyTimezone) -> Decision {
        guard let start = parseTime(startTime), let end = parseTime(endTime),
              let startHour = start.hour, let startMinute = start.minute,
              let endHour = end.hour, let endMinute = end.minute else { return .malformed }
        guard let localNow = localComponents(now, timezone: timezone) else { return .unavailable }
        let startMinutes = startHour * 60 + startMinute
        let endMinutes = endHour * 60 + endMinute
        let spansNextDate = endMinutes <= startMinutes

        for offset in [-1, 0] {
            guard let selectedDate = shiftingLocalDate(localNow, by: offset),
                  isSelected(selectedDate, daysOfWeek: daysOfWeek),
                  let interval = resolvedInterval(
                    on: selectedDate,
                    startHour: startHour,
                    startMinute: startMinute,
                    endHour: endHour,
                    endMinute: endMinute,
                    spansNextDate: spansNextDate,
                    timezone: timezone
                  ) else { continue }
            if interval.end > interval.start, now >= interval.start && now < interval.end { return .inWindow }
        }

        for offset in 0...7 {
            guard let selectedDate = shiftingLocalDate(localNow, by: offset),
                  isSelected(selectedDate, daysOfWeek: daysOfWeek),
                  let interval = resolvedInterval(
                    on: selectedDate,
                    startHour: startHour,
                    startMinute: startMinute,
                    endHour: endHour,
                    endMinute: endMinute,
                    spansNextDate: spansNextDate,
                    timezone: timezone
                  ) else { continue }
            if interval.end > interval.start, interval.start > now { return .pause(until: interval.start) }
        }
        return .unavailable
    }

    static func parseTime(_ timeString: String) -> DateComponents? {
        let bytes = Array(timeString.utf8)
        guard bytes.count == 5, bytes[2] == 58,
              [bytes[0], bytes[1], bytes[3], bytes[4]].allSatisfy({ (48...57).contains($0) }),
              let hour = Int(String(decoding: bytes[0...1], as: UTF8.self)),
              let minute = Int(String(decoding: bytes[3...4], as: UTF8.self)),
              (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        var components = DateComponents(); components.hour = hour; components.minute = minute
        return components
    }

    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    private static func localComponents(_ date: Date, timezone: SignedJourneyTimezone) -> DateComponents? {
        guard let offset = try? timezone.bundle.offsetSeconds(for: timezone, at: date) else { return nil }
        return utc.dateComponents([.year, .month, .day, .hour, .minute, .second, .weekday], from: date.addingTimeInterval(TimeInterval(offset)))
    }

    private static func shiftingLocalDate(_ components: DateComponents, by days: Int) -> DateComponents? {
        guard let year = components.year, let month = components.month, let day = components.day,
              let date = utc.date(from: DateComponents(year: year, month: month, day: day)),
              let shifted = utc.date(byAdding: .day, value: days, to: date) else { return nil }
        return utc.dateComponents([.year, .month, .day, .weekday], from: shifted)
    }

    private static func isSelected(_ date: DateComponents, daysOfWeek: [Int]?) -> Bool {
        guard let daysOfWeek, !daysOfWeek.isEmpty else { return true }
        return daysOfWeek.contains((date.weekday ?? 1) - 1)
    }

    private static func resolvedInterval(
        on date: DateComponents,
        startHour: Int,
        startMinute: Int,
        endHour: Int,
        endMinute: Int,
        spansNextDate: Bool,
        timezone: SignedJourneyTimezone
    ) -> (start: Date, end: Date)? {
        guard let year = date.year, let month = date.month, let day = date.day,
              let endDate = shiftingLocalDate(date, by: spansNextDate ? 1 : 0),
              let endYear = endDate.year, let endMonth = endDate.month, let endDay = endDate.day,
              let start = localToInstant(year, month, day, startHour, startMinute, timezone: timezone, disambiguation: .earlier),
              let end = localToInstant(endYear, endMonth, endDay, endHour, endMinute, timezone: timezone, disambiguation: .later) else { return nil }
        return (start, end)
    }

    private enum Disambiguation { case earlier, later }

    private static func localToInstant(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, timezone: SignedJourneyTimezone, disambiguation: Disambiguation) -> Date? {
        guard let localAsUTC = utc.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)) else { return nil }
        if let exact = exactLocalToInstant(localAsUTC, timezone: timezone, disambiguation: disambiguation) { return exact }
        for delta in 1...2_880 {
            guard let shifted = utc.date(byAdding: .minute, value: delta, to: localAsUTC) else { continue }
            if let candidate = exactLocalToInstant(shifted, timezone: timezone, disambiguation: .earlier) { return candidate }
        }
        return nil
    }

    private static func exactLocalToInstant(_ localAsUTC: Date, timezone: SignedJourneyTimezone, disambiguation: Disambiguation) -> Date? {
        guard let offsets = try? timezone.bundle.nearbyOffsets(for: timezone, around: localAsUTC) else { return nil }
        let expected = utc.dateComponents([.year, .month, .day, .hour, .minute], from: localAsUTC)
        let candidates = offsets.compactMap { offset -> Date? in
            let instant = localAsUTC.addingTimeInterval(-TimeInterval(offset))
            guard let observed = localComponents(instant, timezone: timezone),
                  observed.year == expected.year, observed.month == expected.month, observed.day == expected.day,
                  observed.hour == expected.hour, observed.minute == expected.minute else { return nil }
            return instant
        }.sorted()
        return disambiguation == .later ? candidates.last : candidates.first
    }

}
