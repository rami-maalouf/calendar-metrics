//
//  IntentionalityModels.swift
//  Intent
//
//  Created by Codex on 2026-05-11.
//

import Foundation
import UIKit

struct IntentConfiguration: Codable, Equatable {
    var backendBaseURL = ""
    var setupKey = ""
    var deviceName = UIDevice.current.name
    var deviceId = ""
    var deviceSecret = ""
    var windowDays = 30
    var sampleDataEnabled = false
    /// local hour (0-23) when the daily screen summary notification should fire. default midnight.
    var screenNotificationHour = 0
    /// local minute (0-59) for the screen summary notification.
    var screenNotificationMinute = 0

    enum CodingKeys: String, CodingKey {
        case backendBaseURL
        case setupKey
        case deviceName
        case deviceId
        case deviceSecret
        case windowDays
        case sampleDataEnabled
        case screenNotificationHour
        case screenNotificationMinute
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        backendBaseURL = try container.decodeIfPresent(String.self, forKey: .backendBaseURL) ?? ""
        setupKey = try container.decodeIfPresent(String.self, forKey: .setupKey) ?? ""
        deviceName = try container.decodeIfPresent(String.self, forKey: .deviceName) ?? UIDevice.current.name
        deviceId = try container.decodeIfPresent(String.self, forKey: .deviceId) ?? ""
        deviceSecret = try container.decodeIfPresent(String.self, forKey: .deviceSecret) ?? ""
        windowDays = try container.decodeIfPresent(Int.self, forKey: .windowDays) ?? 30
        sampleDataEnabled = try container.decodeIfPresent(Bool.self, forKey: .sampleDataEnabled) ?? false
        screenNotificationHour = min(
            23,
            max(0, try container.decodeIfPresent(Int.self, forKey: .screenNotificationHour) ?? 0)
        )
        screenNotificationMinute = min(
            59,
            max(0, try container.decodeIfPresent(Int.self, forKey: .screenNotificationMinute) ?? 0)
        )
    }

    var isPaired: Bool {
        !backendBaseURL.isEmpty && !deviceId.isEmpty && !deviceSecret.isEmpty
    }

    /// am times (before noon) summarize the previous calendar day; pm times summarize the fire's calendar day.
    var screenNotificationUsesPreviousDay: Bool {
        screenNotificationHour < 12
    }

    var screenNotificationTimeDate: Date {
        var components = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        components.hour = screenNotificationHour
        components.minute = screenNotificationMinute
        components.second = 0
        return Calendar.current.date(from: components) ?? Date()
    }

    mutating func setScreenNotificationTime(from date: Date) {
        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
        screenNotificationHour = min(23, max(0, components.hour ?? 0))
        screenNotificationMinute = min(59, max(0, components.minute ?? 0))
    }

    func mostRecentScreenNotificationFire(
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Date {
        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.hour = screenNotificationHour
        components.minute = screenNotificationMinute
        components.second = 0
        let todayFire = calendar.date(from: components) ?? now
        if now >= todayFire {
            return todayFire
        }
        return calendar.date(byAdding: .day, value: -1, to: todayFire) ?? todayFire
    }

    func nextScreenNotificationFire(
        after now: Date = Date(),
        calendar: Calendar = .current
    ) -> Date {
        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.hour = screenNotificationHour
        components.minute = screenNotificationMinute
        components.second = 0
        let todayFire = calendar.date(from: components) ?? now
        if now < todayFire {
            return todayFire
        }
        return calendar.date(byAdding: .day, value: 1, to: todayFire) ?? todayFire
    }

    func screenSummaryDayKey(
        forFire fire: Date,
        calendar: Calendar = .current
    ) -> String {
        let fireDay = calendar.startOfDay(for: fire)
        let targetDay =
            screenNotificationUsesPreviousDay
            ? (calendar.date(byAdding: .day, value: -1, to: fireDay) ?? fireDay)
            : fireDay
        return Self.dayKeyFormatter.string(from: targetDay)
    }

    private static let dayKeyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static let storageKey = "intent.ios.configuration"

    static func load() -> IntentConfiguration {
        guard
            let data = UserDefaults.standard.data(forKey: storageKey),
            let decoded = try? JSONDecoder().decode(IntentConfiguration.self, from: data)
        else {
            return IntentConfiguration()
        }

        return decoded
    }

    func persist() {
        guard let data = try? JSONEncoder().encode(self) else {
            return
        }

        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }
}

struct IntentBootstrapRequest: Encodable {
    let setupKey: String
    let deviceName: String
    let platform: String
    let settings: IntentBootstrapSettings
}

struct IntentBootstrapSettings: Encodable {
    let autoStartFocus: Bool
    let autoCompleteFocus: Bool
    let autoShowReview: Bool
    let bundleId: String
}

struct IntentBootstrapResponse: Decodable {
    let ok: Bool
    let device: IntentRegisteredDevice
}

struct IntentRegisteredDevice: Decodable {
    let deviceId: String
    let deviceSecret: String
    let isDefault: Bool
}

struct IntentionalityRecordResponse: Decodable {
    let ok: Bool
}

struct IntentionalitySnapshot: Decodable, Equatable {
    let generatedAt: Int
    let windowDays: Int
    let timeZoneOffsetMinutes: Int
    let totalEntries: Int
    let averageScore: Double
    let todayAverage: Double?
    let yesterdayAverage: Double?
    let deltaFromYesterday: Double?
    let last24Average: Double?
    let currentHourScore: Double?
    let currentStreakDays: Int
    let responseRate7d: Double
    let bestHourOfDay: IntentionalityBestHour?
    let recentEntries: [IntentionalityEntry]
    let dailyAverages: [IntentionalityDailyAverage]
    let hourlyAverages: [IntentionalityHourlyAverage]
    let lastRecordedAt: Int?
    let lastUpdatedAt: Int?
}

struct IntentionalityEntry: Decodable, Equatable, Identifiable {
    let id: String
    let hourStartMs: Int
    let score: Double
    let dayKey: String
    let hour: Int
    let hourLabel: String
    let source: String
    let updatedAt: Int

    var date: Date {
        Date(timeIntervalSince1970: Double(hourStartMs) / 1000)
    }
}

struct IntentionalityDailyAverage: Decodable, Equatable, Identifiable {
    let id: String
    let dayKey: String
    let dayStartMs: Int
    let average: Double
    let count: Int

    var date: Date {
        Date(timeIntervalSince1970: Double(dayStartMs) / 1000)
    }
}

struct IntentionalityHourlyAverage: Decodable, Equatable, Identifiable {
    let id: String
    let hour: Int
    let label: String
    let average: Double?
    let count: Int
}

struct IntentionalityBestHour: Decodable, Equatable {
    let id: String
    let hour: Int
    let label: String
    let average: Double
    let count: Int
}

struct IntentScreenApp: Decodable, Equatable {
    let bundleId: String
    let title: String
    let seconds: Double
}

struct IntentScreenHour: Decodable, Equatable, Identifiable {
    let hourOfDay: Int
    let hourStartMs: Int
    let totalSeconds: Double
    let topApps: [IntentScreenApp]

    var id: Int { hourOfDay }
}

struct IntentScreenDay: Decodable, Equatable {
    let dayKey: String
    let source: String
    let sourceDeviceId: String
    let platform: String
    let totalSeconds: Double
    let eventCount: Int
    let cleanedEventCount: Int
    let topApps: [IntentScreenApp]
    let hourlyTotals: [Double]
    let hours: [IntentScreenHour]?
    let notificationBody: String
    let notificationDeliveredAt: Int?
    let timeZoneOffsetMinutes: Int
    let collectedAt: Int

    func markingNotificationDelivered(
        at timestampMs: Int = Int(Date().timeIntervalSince1970 * 1000)
    ) -> IntentScreenDay {
        IntentScreenDay(
            dayKey: dayKey,
            source: source,
            sourceDeviceId: sourceDeviceId,
            platform: platform,
            totalSeconds: totalSeconds,
            eventCount: eventCount,
            cleanedEventCount: cleanedEventCount,
            topApps: topApps,
            hourlyTotals: hourlyTotals,
            hours: hours,
            notificationBody: notificationBody,
            notificationDeliveredAt: timestampMs,
            timeZoneOffsetMinutes: timeZoneOffsetMinutes,
            collectedAt: collectedAt
        )
    }
}

struct IntentScreenSummaryResponse: Decodable {
    let ok: Bool
    let day: IntentScreenDay?
}

struct IntentScreenRecentResponse: Decodable {
    let ok: Bool
    let days: [IntentScreenDay]
}

struct IntentScreenSummaryRequest: Encodable {
    let deviceId: String
    let deviceSecret: String
    let dayKey: String?
    let includeHours: Bool
}

struct IntentScreenRecentRequest: Encodable {
    let deviceId: String
    let deviceSecret: String
    let limit: Int
}

struct IntentScreenAckRequest: Encodable {
    let deviceId: String
    let deviceSecret: String
    let dayKey: String
    let sourceDeviceId: String
}

struct IntentScreenAckResponse: Decodable {
    let ok: Bool
    let dayKey: String?
    let notificationDeliveredAt: Int?
}
