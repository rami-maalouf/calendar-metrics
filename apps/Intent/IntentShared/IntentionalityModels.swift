//
//  IntentionalityModels.swift
//  Intent + IntentWidgetsExtension
//
//  Single source of truth for the intentionality snapshot shared between the
//  app (fetches from the backend, publishes to the app group) and the widget
//  (reads from the app group). Compiled into both targets.
//

import Foundation
import SwiftUI

struct IntentIntentionalityState: Codable, Equatable {
    struct HourEntry: Codable, Equatable, Identifiable {
        let dayKey: String
        let hour: Int
        let hourLabel: String
        let hourStartMs: Double
        let id: String
        let score: Double
        let source: String?
        let updatedAt: Double?
    }

    struct DailyAverage: Codable, Equatable, Identifiable {
        // null when the backend zero-fills a day with no logged hours
        let average: Double?
        let count: Int
        let dayKey: String
        let dayStartMs: Double

        var id: String { dayKey }
    }

    struct HourlyAverage: Codable, Equatable, Identifiable {
        // null for hours never logged (the backend returns all 24 hours)
        let average: Double?
        let count: Int
        let hour: Int
        let label: String

        var id: Int { hour }
    }

    struct BestHour: Codable, Equatable {
        let average: Double
        let count: Int
        let hour: Int
        let label: String
    }

    let averageScore: Double?
    let bestHourOfDay: BestHour?
    let currentHourScore: Double?
    let currentStreakDays: Int?
    let dailyAverages: [DailyAverage]?
    let deltaFromYesterday: Double?
    let generatedAt: Double?
    let hourlyAverages: [HourlyAverage]?
    let last24Average: Double?
    let lastRecordedAt: Double?
    let lastUpdatedAt: Double?
    let recentEntries: [HourEntry]?
    let responseRate7d: Double?
    let timeZoneOffsetMinutes: Double?
    let todayAverage: Double?
    let totalEntries: Int?
    let windowDays: Int?
    let yesterdayAverage: Double?

    var todayEntries: [HourEntry] {
        let key = Self.dayKey(for: Date())
        return (recentEntries ?? []).filter { $0.dayKey == key }
    }

    static func dayKey(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar.current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

struct IntentTrackedHoursSnapshot: Codable, Equatable {
    struct Day: Codable, Equatable, Identifiable {
        let dayStartMs: Double
        let durationMs: Double
        let sessionCount: Int

        var id: Double { dayStartMs }
        var hours: Double { durationMs / 3_600_000 }
    }

    let days: [Day]
    let generatedAt: Double
    let windowDays: Int
}

enum IntentWidgetShared {
    static let appGroupId = "3V2UU7RRK9.studio.orbitlabs.intent"
    static let snapshotKey = "intentionalitySnapshotJson"
    static let intentionalityWidgetKind = "IntentionalityToday"
    static let trendWidgetKind = "IntentionalityTrend"
    static let trendRangeKey = "intentionalityTrendRangeDays"
    static let trackedHoursKey = "trackedHoursSnapshotJson"
    static let trackedHoursWidgetKind = "IntentTrackedHours"
    static let trackedHoursRangeKey = "trackedHoursRangeDays"
    static let allowedTrendRanges = [7, 30, 90]

    static func loadTrendRangeDays() -> Int {
        let stored = UserDefaults(suiteName: appGroupId)?.integer(forKey: trendRangeKey) ?? 0
        return allowedTrendRanges.contains(stored) ? stored : 7
    }

    static func saveTrendRangeDays(_ days: Int) {
        guard allowedTrendRanges.contains(days) else { return }
        UserDefaults(suiteName: appGroupId)?.set(days, forKey: trendRangeKey)
    }

    static func loadTrackedHoursRangeDays() -> Int {
        let stored = UserDefaults(suiteName: appGroupId)?.integer(forKey: trackedHoursRangeKey) ?? 0
        return allowedTrendRanges.contains(stored) ? stored : 7
    }

    static func saveTrackedHoursRangeDays(_ days: Int) {
        guard allowedTrendRanges.contains(days) else { return }
        UserDefaults(suiteName: appGroupId)?.set(days, forKey: trackedHoursRangeKey)
    }

    static func loadTrackedHours() -> IntentTrackedHoursSnapshot? {
        guard
            let defaults = UserDefaults(suiteName: appGroupId),
            let raw = defaults.string(forKey: trackedHoursKey),
            let data = raw.data(using: .utf8)
        else {
            return nil
        }
        return try? JSONDecoder().decode(IntentTrackedHoursSnapshot.self, from: data)
    }

    @discardableResult
    static func saveTrackedHours(_ snapshot: IntentTrackedHoursSnapshot) -> Bool {
        guard
            let defaults = UserDefaults(suiteName: appGroupId),
            let data = try? JSONEncoder().encode(snapshot),
            let json = String(data: data, encoding: .utf8)
        else {
            return false
        }
        defaults.set(json, forKey: trackedHoursKey)
        return true
    }

    // diverging scale for the 1-5 score: warm low pole, neutral midpoint,
    // green high pole (matches the intentionality hue in the app's visuals)
    static func scoreColor(_ score: Double) -> Color {
        switch score {
        case ..<1.5: return Color(red: 0.76, green: 0.25, blue: 0.05)
        case ..<2.5: return Color(red: 0.98, green: 0.57, blue: 0.24)
        case ..<3.5: return Color(red: 0.61, green: 0.64, blue: 0.69)
        case ..<4.5: return Color(red: 0.35, green: 0.75, blue: 0.35)
        default: return Color(red: 0.04, green: 0.55, blue: 0.04)
        }
    }

    static func loadSnapshot() -> IntentIntentionalityState? {
        guard
            let defaults = UserDefaults(suiteName: appGroupId),
            let raw = defaults.string(forKey: snapshotKey),
            let data = raw.data(using: .utf8)
        else {
            return nil
        }
        return try? JSONDecoder().decode(IntentIntentionalityState.self, from: data)
    }

    // temporary diagnostics: unified log redacts interpolated NSLog output,
    // so breadcrumbs go to a file in the shared container instead
    static func debugLog(_ message: String) {
        guard
            let url = FileManager.default
                .containerURL(forSecurityApplicationGroupIdentifier: appGroupId)?
                .appendingPathComponent("debug.log")
        else {
            return
        }

        let line = "\(Date()) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }

        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }

    @discardableResult
    static func saveSnapshot(_ state: IntentIntentionalityState) -> Bool {
        guard
            let defaults = UserDefaults(suiteName: appGroupId),
            let data = try? JSONEncoder().encode(state),
            let json = String(data: data, encoding: .utf8)
        else {
            return false
        }
        defaults.set(json, forKey: snapshotKey)
        return true
    }
}

extension IntentTrackedHoursSnapshot {
    // placeholder data for widget previews and the gallery
    static var sample: IntentTrackedHoursSnapshot {
        let now = Date()
        let calendar = Calendar.current
        let days: [Day] = (0..<90).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: now) else {
                return nil
            }
            let start = calendar.startOfDay(for: day)
            // deterministic wave with weekend dips so previews look plausible
            let base = 3.5 + 1.8 * sin(Double(offset) / 3.2)
            let hours = max(0, offset % 7 >= 5 ? base - 2.5 : base)
            guard hours > 0.2 else {
                return nil
            }
            return Day(
                dayStartMs: start.timeIntervalSince1970 * 1000,
                durationMs: hours * 3_600_000,
                sessionCount: max(1, Int(hours / 1.5))
            )
        }
        return IntentTrackedHoursSnapshot(
            days: days,
            generatedAt: now.timeIntervalSince1970 * 1000,
            windowDays: 90
        )
    }
}

extension IntentIntentionalityState {
    // placeholder data for widget previews and the gallery
    static var sample: IntentIntentionalityState {
        let now = Date()
        let todayKey = IntentIntentionalityState.dayKey(for: now)
        let hours: [HourEntry] = (7...15).map { hour in
            HourEntry(
                dayKey: todayKey,
                hour: hour,
                hourLabel: "\(hour)",
                hourStartMs: 0,
                id: "sample-\(hour)",
                score: [3, 4, 5, 4, 2, 4, 5, 5, 3][hour - 7],
                source: "sample",
                updatedAt: nil
            )
        }
        let calendar = Calendar.current
        let days: [DailyAverage] = (0..<90).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: now) else {
                return nil
            }
            let start = calendar.startOfDay(for: day)
            // deterministic wave so previews look plausible
            let value = 3.4 + 1.2 * sin(Double(offset) / 4.5) - (offset % 7 == 0 ? 0.8 : 0)
            return DailyAverage(
                average: min(5, max(1, value)),
                count: 10,
                dayKey: IntentIntentionalityState.dayKey(for: start),
                dayStartMs: start.timeIntervalSince1970 * 1000
            )
        }
        return IntentIntentionalityState(
            averageScore: 4.2,
            bestHourOfDay: BestHour(average: 5, count: 5, hour: 8, label: "8 AM"),
            currentHourScore: 4,
            currentStreakDays: 31,
            dailyAverages: days,
            deltaFromYesterday: 0.4,
            generatedAt: nil,
            hourlyAverages: nil,
            last24Average: 3.9,
            lastRecordedAt: nil,
            lastUpdatedAt: nil,
            recentEntries: hours,
            responseRate7d: 62,
            timeZoneOffsetMinutes: nil,
            todayAverage: 3.9,
            totalEntries: 335,
            windowDays: 35,
            yesterdayAverage: 3.5
        )
    }
}
