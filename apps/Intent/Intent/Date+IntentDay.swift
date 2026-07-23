//
//  Date+IntentDay.swift
//  Intent
//
//  Intent days start at 4:00 AM local time. Midnight through 3:59 AM belong
//  to the previous calendar day for metrics, charts, and "today" summaries.
//

import Foundation

enum IntentDay {
    static let startHour = 4

    /// Shifts early-morning timestamps onto the previous calendar date so
    /// `Calendar` day comparisons reflect the Intent day boundary.
    static func logicalDate(for date: Date, calendar: Calendar = .current) -> Date {
        let hour = calendar.component(.hour, from: date)
        if hour < startHour {
            return calendar.date(byAdding: .day, value: -1, to: date) ?? date
        }
        return date
    }

    /// Start of the Intent day containing `date` (local 4:00 AM).
    static func start(of date: Date, calendar: Calendar = .current) -> Date {
        let day = calendar.startOfDay(for: logicalDate(for: date, calendar: calendar))
        return calendar.date(byAdding: .hour, value: startHour, to: day) ?? day
    }

    /// Exclusive end of the Intent day containing `date` (next local 4:00 AM).
    static func end(of date: Date, calendar: Calendar = .current) -> Date {
        let dayStart = start(of: date, calendar: calendar)
        return calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
    }

    static func isSameDay(_ lhs: Date, _ rhs: Date, calendar: Calendar = .current) -> Bool {
        calendar.isDate(
            logicalDate(for: lhs, calendar: calendar),
            inSameDayAs: logicalDate(for: rhs, calendar: calendar)
        )
    }

    static func dayKey(for date: Date, calendar: Calendar = .current) -> String {
        let components = calendar.dateComponents(
            [.year, .month, .day],
            from: logicalDate(for: date, calendar: calendar)
        )
        let year = components.year ?? 0
        let month = components.month ?? 1
        let day = components.day ?? 1
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    /// Minutes east of UTC, matching the backend intentionality offset convention.
    static func timeZoneOffsetMinutes(for date: Date = Date()) -> Int {
        TimeZone.current.secondsFromGMT(for: date) / 60
    }
}

extension Date {
    var intentLogicalDate: Date {
        IntentDay.logicalDate(for: self)
    }

    var intentDayStart: Date {
        IntentDay.start(of: self)
    }

    var intentDayEnd: Date {
        IntentDay.end(of: self)
    }

    func isSameIntentDay(as other: Date) -> Bool {
        IntentDay.isSameDay(self, other)
    }
}
