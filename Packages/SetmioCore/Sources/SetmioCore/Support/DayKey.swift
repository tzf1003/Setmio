import Foundation

/// A local calendar day. All "per day" data (metrics, readiness, intake) is keyed by this,
/// never by a `Date`, so travel and DST never shift a day's bucket.
public struct DayKey: Hashable, Codable, Sendable, Comparable, CustomStringConvertible {
    public let year: Int
    public let month: Int
    public let day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    public init(_ date: Date, calendar: Calendar = .setmioDefault) {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(year: c.year ?? 1970, month: c.month ?? 1, day: c.day ?? 1)
    }

    /// `yyyymmdd` as an integer — used as a unique key in persistence layers.
    public var sortKey: Int { year * 10_000 + month * 100 + day }

    public init(sortKey: Int) {
        self.init(year: sortKey / 10_000, month: (sortKey / 100) % 100, day: sortKey % 100)
    }

    public var description: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    public static func < (lhs: DayKey, rhs: DayKey) -> Bool {
        lhs.sortKey < rhs.sortKey
    }

    /// Start of this day in the given calendar's time zone.
    public func startOfDay(calendar: Calendar = .setmioDefault) -> Date {
        date(atHour: 0, minute: 0, calendar: calendar)
    }

    public func date(atHour hour: Int, minute: Int = 0, calendar: Calendar = .setmioDefault) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = 0
        return calendar.date(from: components) ?? Date(timeIntervalSince1970: 0)
    }

    public func adding(days: Int, calendar: Calendar = .setmioDefault) -> DayKey {
        let base = startOfDay(calendar: calendar)
        let shifted = calendar.date(byAdding: .day, value: days, to: base) ?? base
        return DayKey(shifted, calendar: calendar)
    }

    /// Number of calendar days from `other` to `self` (positive when `self` is later).
    public func daysSince(_ other: DayKey, calendar: Calendar = .setmioDefault) -> Int {
        let a = other.startOfDay(calendar: calendar)
        let b = startOfDay(calendar: calendar)
        return calendar.dateComponents([.day], from: a, to: b).day ?? 0
    }

    public static func range(from start: DayKey, to end: DayKey, calendar: Calendar = .setmioDefault) -> [DayKey] {
        guard start <= end else { return [] }
        var days: [DayKey] = []
        var cursor = start
        while cursor <= end {
            days.append(cursor)
            cursor = cursor.adding(days: 1, calendar: calendar)
            if days.count > 10_000 { break }
        }
        return days
    }
}

public extension Calendar {
    /// Gregorian calendar in Asia/Shanghai. Engines accept a calendar parameter so tests stay deterministic.
    static let setmioDefault: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        calendar.locale = Locale(identifier: "zh_CN")
        return calendar
    }()

    static func setmio(timeZoneIdentifier: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZoneIdentifier) ?? .current
        calendar.locale = Locale(identifier: "zh_CN")
        return calendar
    }
}
