import Foundation

extension Date {
    /// Local hour when a new journal / Intent day begins.
    /// Midnight through 3:59 AM belong to the previous calendar day.
    static let journalDayStartHour = 4

    /// Returns the "journal date" for this Date.
    /// The journal day starts at 4 AM instead of midnight.
    /// So 1:00 AM on January 8th is treated as January 7th for journal purposes.
    var journalDate: Date {
        let calendar = Calendar.current
        let hour = calendar.component(.hour, from: self)

        // If it's before 4 AM, treat it as the previous day
        if hour < Self.journalDayStartHour {
            return calendar.date(byAdding: .day, value: -1, to: self) ?? self
        }
        return self
    }

    /// Start of the journal day containing this date (local 4:00 AM).
    var journalDayStart: Date {
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: journalDate)
        return calendar.date(byAdding: .hour, value: Self.journalDayStartHour, to: day) ?? day
    }

    /// Exclusive end of the journal day containing this date (next local 4:00 AM).
    var journalDayEnd: Date {
        Calendar.current.date(byAdding: .day, value: 1, to: journalDayStart) ?? journalDayStart
    }

    func isSameJournalDay(as other: Date) -> Bool {
        Calendar.current.isDate(journalDate, inSameDayAs: other.journalDate)
    }

    var ordinalDateString: String {
        let calendar = Calendar.current
        let day = calendar.component(.day, from: self)
        let numberFormatter = NumberFormatter()
        numberFormatter.numberStyle = .ordinal
        let dayString = numberFormatter.string(from: NSNumber(value: day)) ?? "\(day)"
        return dayString
    }
}
