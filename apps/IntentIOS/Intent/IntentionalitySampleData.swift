import Foundation

enum IntentionalitySampleData {
    private struct SampleDayProfile {
        let baseline: Double
        let volatility: Double
        let completionRate: Double
    }

    static func snapshot(windowDays: Int, currentHourScore: Double? = nil) -> IntentionalitySnapshot {
        let calendar = Calendar.current
        let now = Date()
        let clampedWindow = min(max(windowDays, 7), 90)
        let actualHour = calendar.component(.hour, from: now)
        let previewHour = max(actualHour, 14)
        let todayStart = calendar.startOfDay(for: now)
        let currentHourStart = calendar.date(byAdding: .hour, value: previewHour, to: todayStart)
            ?? calendar.dateInterval(of: .hour, for: now)?.start
            ?? now
        let generatedAt = milliseconds(now)
        let offsetMinutes = TimeZone.current.secondsFromGMT(for: now) / 60

        let entries = sampleEntries(
            calendar: calendar,
            currentHourStart: currentHourStart,
            windowDays: clampedWindow,
            currentHourScore: currentHourScore
        )

        let groupedByDay = Dictionary(grouping: entries, by: \.dayKey)
        let dailyAverages = (0..<clampedWindow).compactMap { offset -> IntentionalityDailyAverage? in
            guard let date = calendar.date(byAdding: .day, value: -(clampedWindow - 1 - offset), to: calendar.startOfDay(for: now)) else {
                return nil
            }
            let key = dayKey(for: date, calendar: calendar)
            let dayEntries = groupedByDay[key] ?? []
            let average = dayEntries.isEmpty ? nil : dayEntries.map(\.score).reduce(0, +) / Double(dayEntries.count)

            return IntentionalityDailyAverage(
                id: key,
                dayKey: key,
                dayStartMs: milliseconds(date),
                average: average ?? 0,
                count: dayEntries.count
            )
        }

        let populatedDailyAverages = dailyAverages.filter { $0.count > 0 }
        let averageScore = average(entries.map(\.score)) ?? 0
        let todayKey = dayKey(for: now, calendar: calendar)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now) ?? now
        let yesterdayKey = dayKey(for: yesterday, calendar: calendar)
        let todayAverage = average((groupedByDay[todayKey] ?? []).map(\.score))
        let yesterdayAverage = average((groupedByDay[yesterdayKey] ?? []).map(\.score))
        let last24Start = calendar.date(byAdding: .hour, value: -24, to: currentHourStart) ?? currentHourStart
        let last24Average = average(entries.filter { $0.date >= last24Start }.map(\.score))
        let hourlyAverages = hourlyAverages(from: entries)
        let bestHour = hourlyAverages
            .compactMap { hour -> IntentionalityBestHour? in
                guard let average = hour.average else { return nil }
                return IntentionalityBestHour(id: hour.id, hour: hour.hour, label: hour.label, average: average, count: hour.count)
            }
            .max { $0.average < $1.average }

        return IntentionalitySnapshot(
            generatedAt: generatedAt,
            windowDays: windowDays,
            timeZoneOffsetMinutes: offsetMinutes,
            totalEntries: entries.count,
            averageScore: averageScore,
            todayAverage: todayAverage,
            yesterdayAverage: yesterdayAverage,
            deltaFromYesterday: delta(todayAverage, yesterdayAverage),
            last24Average: last24Average,
            currentHourScore: currentHourScore ?? entries.first(where: { $0.hourStartMs == milliseconds(currentHourStart) })?.score,
            currentStreakDays: streakDays(from: groupedByDay, calendar: calendar, now: now),
            responseRate7d: responseRate(entries: entries, calendar: calendar, now: now),
            bestHourOfDay: bestHour,
            recentEntries: entries.sorted { $0.hourStartMs > $1.hourStartMs },
            dailyAverages: populatedDailyAverages,
            hourlyAverages: hourlyAverages,
            lastRecordedAt: entries.map(\.updatedAt).max(),
            lastUpdatedAt: generatedAt
        )
    }

    private static func sampleEntries(
        calendar: Calendar,
        currentHourStart: Date,
        windowDays: Int,
        currentHourScore: Double?
    ) -> [IntentionalityEntry] {
        var entries: [IntentionalityEntry] = []

        for dayOffset in stride(from: windowDays - 1, through: 0, by: -1) {
            guard let day = calendar.date(byAdding: .day, value: -dayOffset, to: calendar.startOfDay(for: currentHourStart)) else {
                continue
            }
            let dayProfile = sampleDayProfile()

            for hour in 7...22 {
                if shouldSkip(dayProfile: dayProfile, hour: hour) {
                    continue
                }

                guard let hourStart = calendar.date(byAdding: .hour, value: hour, to: day), hourStart <= currentHourStart else {
                    continue
                }

                let score: Double
                if hourStart == currentHourStart, let currentHourScore {
                    score = currentHourScore
                } else {
                    score = sampleScore(dayProfile: dayProfile, hour: hour)
                }

                entries.append(
                    IntentionalityEntry(
                        id: "sample-\(milliseconds(hourStart))",
                        hourStartMs: milliseconds(hourStart),
                        score: score,
                        dayKey: dayKey(for: hourStart, calendar: calendar),
                        hour: hour,
                        hourLabel: hourLabel(for: hour),
                        source: "sample_data",
                        updatedAt: milliseconds(hourStart.addingTimeInterval(60 * 8))
                    )
                )
            }
        }

        return entries
    }

    private static func sampleDayProfile() -> SampleDayProfile {
        let roll = Double.random(in: 0...1)
        switch roll {
        case 0..<0.22:
            return SampleDayProfile(
                baseline: Double.random(in: 3.1...4.1),
                volatility: Double.random(in: 0.8...1.4),
                completionRate: Double.random(in: 0.42...0.68)
            )
        case 0.22..<0.48:
            return SampleDayProfile(
                baseline: Double.random(in: 5.7...6.6),
                volatility: Double.random(in: 0.35...0.9),
                completionRate: Double.random(in: 0.75...0.95)
            )
        default:
            return SampleDayProfile(
                baseline: Double.random(in: 4.2...5.7),
                volatility: Double.random(in: 0.5...1.1),
                completionRate: Double.random(in: 0.58...0.88)
            )
        }
    }

    private static func sampleScore(dayProfile: SampleDayProfile, hour: Int) -> Double {
        let hourEffect: Double
        switch hour {
        case 7...8:
            hourEffect = Double.random(in: -0.5...0.45)
        case 9...11:
            hourEffect = Double.random(in: 0.0...0.75)
        case 12...14:
            hourEffect = Double.random(in: -0.75...0.35)
        case 15...17:
            hourEffect = Double.random(in: -0.2...0.65)
        case 18...20:
            hourEffect = Double.random(in: -0.7...0.25)
        default:
            hourEffect = Double.random(in: -1.0...0.15)
        }

        let localNoise = Double.random(in: -dayProfile.volatility...dayProfile.volatility)
        let occasionalSwing = Double.random(in: 0...1) < 0.14 ? Double.random(in: -1.6...1.2) : 0
        let rawScore = dayProfile.baseline + hourEffect + localNoise + occasionalSwing
        return min(7, max(3, (rawScore * 10).rounded() / 10))
    }

    private static func shouldSkip(dayProfile: SampleDayProfile, hour: Int) -> Bool {
        let hourPenalty: Double
        switch hour {
        case 7...8:
            hourPenalty = 0.16
        case 19...22:
            hourPenalty = 0.2
        default:
            hourPenalty = 0
        }

        return Double.random(in: 0...1) > max(0.05, dayProfile.completionRate - hourPenalty)
    }

    private static func hourlyAverages(from entries: [IntentionalityEntry]) -> [IntentionalityHourlyAverage] {
        let grouped = Dictionary(grouping: entries, by: \.hour)
        return (0..<24).map { hour in
            let hourEntries = grouped[hour] ?? []
            return IntentionalityHourlyAverage(
                id: "\(hour)",
                hour: hour,
                label: hourLabel(for: hour),
                average: average(hourEntries.map(\.score)),
                count: hourEntries.count
            )
        }
    }

    private static func responseRate(entries: [IntentionalityEntry], calendar: Calendar, now: Date) -> Double {
        let start = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now)) ?? now
        let recentCount = entries.filter { $0.date >= start }.count
        let expected = 7 * 16
        return min(100, Double(recentCount) / Double(expected) * 100)
    }

    private static func streakDays(from groupedByDay: [String: [IntentionalityEntry]], calendar: Calendar, now: Date) -> Int {
        var streak = 0
        for offset in 0..<90 {
            guard let date = calendar.date(byAdding: .day, value: -offset, to: now) else { break }
            let key = dayKey(for: date, calendar: calendar)
            guard let entries = groupedByDay[key], !entries.isEmpty else { break }
            streak += 1
        }
        return streak
    }

    private static func average(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    private static func delta(_ lhs: Double?, _ rhs: Double?) -> Double? {
        guard let lhs, let rhs else { return nil }
        return lhs - rhs
    }

    private static func dayKey(for date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    private static func hourLabel(for hour: Int) -> String {
        let normalized = ((hour % 24) + 24) % 24
        return "\(normalized)"
    }

    private static func milliseconds(_ date: Date) -> Int {
        Int(date.timeIntervalSince1970 * 1000)
    }
}
