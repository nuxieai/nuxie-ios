import Foundation

/// Deterministic calendar math for Journey v2 time windows.
/// All timezone offsets come from the verified, pinned IANA bundle.
enum TimeWindowMath {
    static let currentDeviceTimezoneToken = "__current_device__"

    enum Decision: Equatable {
        case malformed
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
              let endHour = end.hour, let endMinute = end.minute,
              let localNow = localComponents(now, timezone: timezone) else { return .malformed }
        let weekday = (localNow.weekday ?? 1) - 1
        if let days = daysOfWeek, !days.isEmpty, !days.contains(weekday) {
            return .pause(until: nextValidDay(from: now, validDays: days, timezone: timezone))
        }
        let currentMinutes = (localNow.hour ?? 0) * 60 + (localNow.minute ?? 0)
        let startMinutes = startHour * 60 + startMinute
        let endMinutes = endHour * 60 + endMinute
        if startMinutes == endMinutes { return .inWindow }
        let inWindow = startMinutes <= endMinutes
            ? currentMinutes >= startMinutes && currentMinutes < endMinutes
            : currentMinutes >= startMinutes || currentMinutes < endMinutes
        if inWindow { return .inWindow }
        return .pause(until: nextWindowOpen(from: now, startTime: startTime, timezone: timezone, validDays: daysOfWeek))
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

    private static func nextValidDay(from date: Date, validDays: [Int], timezone: SignedJourneyTimezone) -> Date {
        guard let local = localComponents(date, timezone: timezone), let year = local.year, let month = local.month, let day = local.day else { return date }
        guard let base = utc.date(from: DateComponents(year: year, month: month, day: day)) else { return date }
        for increment in 1...7 {
            guard let next = utc.date(byAdding: .day, value: increment, to: base) else { continue }
            let nextLocalDate = utc.dateComponents([.year, .month, .day, .weekday], from: next)
            guard let nextYear = nextLocalDate.year, let nextMonth = nextLocalDate.month, let nextDay = nextLocalDate.day,
                  validDays.contains((nextLocalDate.weekday ?? 1) - 1) else { continue }
            return localToInstant(nextYear, nextMonth, nextDay, 0, 0, timezone: timezone, disambiguation: .earlier) ?? date
        }
        return date
    }

    private static func nextWindowOpen(from date: Date, startTime: String, timezone: SignedJourneyTimezone, validDays: [Int]?) -> Date {
        guard let local = localComponents(date, timezone: timezone), let hm = parseTime(startTime), let hour = hm.hour, let minute = hm.minute,
              let year = local.year, let month = local.month, let day = local.day else { return date }
        var candidate = localToInstant(year, month, day, hour, minute, timezone: timezone, disambiguation: .earlier) ?? date
        if candidate <= date { candidate = localToInstant(year, month, day + 1, hour, minute, timezone: timezone, disambiguation: .earlier) ?? candidate }
        guard let days = validDays, !days.isEmpty else { return candidate }
        for _ in 0..<8 {
            if let parts = localComponents(candidate, timezone: timezone), days.contains((parts.weekday ?? 1) - 1) { return candidate }
            candidate = localToInstantFromDate(candidate, timezone: timezone, hour: hour, minute: minute) ?? candidate.addingTimeInterval(86_400)
        }
        return candidate
    }

    private enum Disambiguation { case earlier, later }

    private static func localToInstant(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, timezone: SignedJourneyTimezone, disambiguation: Disambiguation) -> Date? {
        guard let localAsUTC = utc.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)) else { return nil }
        if let exact = exactLocalToInstant(localAsUTC, timezone: timezone, disambiguation: disambiguation) { return exact }
        for delta in 1...180 {
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

    private static func localToInstantFromDate(_ date: Date, timezone: SignedJourneyTimezone, hour: Int, minute: Int) -> Date? {
        guard let local = localComponents(date, timezone: timezone), let year = local.year, let month = local.month, let day = local.day else { return nil }
        return localToInstant(year, month, day + 1, hour, minute, timezone: timezone, disambiguation: .earlier)
    }
}
