import Foundation

/// A local calendar day (e.g. `2026-11-11`). Streaks and daily chapters are keyed by
/// the day the user experienced, not by an absolute timestamp, so travel across time
/// zones never silently breaks a streak.
public struct DayKey: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let year: Int
    public let month: Int
    public let day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    public init(_ date: Date, calendar: Calendar = .current) {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(year: parts.year ?? 1970, month: parts.month ?? 1, day: parts.day ?? 1)
    }

    public init?(string: String) {
        let parts = string.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        self.init(year: parts[0], month: parts[1], day: parts[2])
    }

    public func startDate(in calendar: Calendar = .current) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day)) ?? .distantPast
    }

    public func endDate(in calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: .day, value: 1, to: startDate(in: calendar)) ?? .distantFuture
    }

    /// Whole days from `self` to `other` (positive when `other` is later).
    public func days(until other: DayKey, calendar: Calendar = .current) -> Int {
        calendar.dateComponents([.day], from: startDate(in: calendar), to: other.startDate(in: calendar)).day ?? 0
    }

    public func adding(days: Int, calendar: Calendar = .current) -> DayKey {
        let date = calendar.date(byAdding: .day, value: days, to: startDate(in: calendar)) ?? startDate(in: calendar)
        return DayKey(date, calendar: calendar)
    }

    public static func < (lhs: DayKey, rhs: DayKey) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }

    public var description: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }
}

extension DayKey: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let key = DayKey(string: raw) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid DayKey \(raw)")
        }
        self = key
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}
