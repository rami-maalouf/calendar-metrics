//
//  IntentModels.swift
//  Intent
//
//  Created by Codex on 2026-03-10.
//

import Foundation

struct IntentLocalConfiguration: Codable, Equatable {
    var backendBaseURL = ""
    var setupKey = ""
    var deviceName = Host.current().localizedName ?? "Intent Mac"
    var deviceId = ""
    var deviceSecret = ""
    var autoStartFocus = true
    var autoCompleteFocus = true
    var autoShowReview = true
    var dailyReportEnabled = false
    var dailyReportTimeMinutes = 21 * 60
    var notifyWhenDailyReportReady = true
    var startShortcutName = "Start Focus Session"
    var completeShortcutName = "Complete Focus Session"
    var bundleID = Bundle.main.bundleIdentifier ?? "studio.orbitlabs.Intent"

    var isPaired: Bool {
        !backendBaseURL.isEmpty && !deviceId.isEmpty && !deviceSecret.isEmpty
    }

    static let storageKey = "intent.local.configuration"

    static func load() -> IntentLocalConfiguration {
        guard
            let data = UserDefaults.standard.data(forKey: storageKey),
            let decoded = try? JSONDecoder().decode(IntentLocalConfiguration.self, from: data)
        else {
            return IntentLocalConfiguration()
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
    let settings: IntentDeviceSettingsPayload
}

struct IntentDeviceSettingsPayload: Encodable {
    let autoStartFocus: Bool
    let autoCompleteFocus: Bool
    let autoShowReview: Bool
    let startShortcutName: String
    let completeShortcutName: String
    let bundleId: String
}

struct IntentDevicePollRequest: Encodable {
    let deviceId: String
    let deviceSecret: String
    let settings: IntentDeviceSettingsPayload
}

struct IntentDeviceMetricsRequest: Encodable {
    let deviceId: String
    let deviceSecret: String
    let windowDays: Int
    let timeZoneOffsetMinutes: Int
}

struct IntentDeviceDailyReportRequest: Encodable {
    let deviceId: String
    let deviceSecret: String
    let startTimeMs: Int
    let endTimeMs: Int
}

struct IntentSessionActionRequest: Encodable {
    let deviceId: String
    let deviceSecret: String
    let sessionId: String
}

struct IntentSubmitReviewRequest: Encodable {
    let deviceId: String
    let deviceSecret: String
    let sessionId: String
    let numericMetrics: [String: Int]
    let countMetrics: [String: Int]
    let booleanMetrics: [String: Bool]
    let taskCategory: String?
    let projectName: String?
    let whatWentWell: String?
    let whatDidntGoWell: String?
}

struct IntentBootstrapResponse: Decodable {
    let ok: Bool
    let device: IntentRegisteredDevice
    let integration: IntentIntegrationState
    let webhook: IntentWebhookStatus
}

struct IntentRegisteredDevice: Decodable {
    let deviceId: String
    let deviceSecret: String
    let isDefault: Bool
}

struct IntentWebhookStatus: Decodable {
    let configured: Bool
    let reason: String?
    let workspaceId: Int?
    let callbackUrl: String?
    let subscriptionId: Int?
    let validatedAt: Int?
}

struct IntentDevicePollEnvelope: Decodable {
    let ok: Bool
    let state: IntentDeviceState
}

struct IntentDeviceDashboardEnvelope: Decodable {
    let ok: Bool
    let state: IntentDashboardState
}

struct IntentDeviceMetricsEnvelope: Decodable {
    let ok: Bool
    let state: IntentMetricsState
}

struct IntentDailyReportContextEnvelope: Decodable {
    let ok: Bool
    let state: IntentDailyReportContext
}

struct IntentDeviceIntentionalityRequest: Encodable {
    let deviceId: String
    let deviceSecret: String
    let windowDays: Int
    let timeZoneOffsetMinutes: Int
}

struct IntentIntentionalityEnvelope: Decodable {
    let ok: Bool
    let state: IntentIntentionalityState
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

struct IntentScreenDay: Decodable, Equatable, Identifiable {
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

    var id: String { "\(dayKey)-\(sourceDeviceId)" }
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

struct IntentScreenSummaryResponse: Decodable {
    let ok: Bool
    let day: IntentScreenDay?
}

struct IntentScreenRecentResponse: Decodable {
    let ok: Bool
    let days: [IntentScreenDay]
}

// IntentIntentionalityState lives in IntentShared/IntentionalityModels.swift,
// compiled into both the app and the widget extension.

struct IntentPullResponse: Decodable {
    let ok: Bool
    let pulled: Bool
    let reason: String?
}

struct IntentDeviceState: Decodable {
    let device: IntentDeviceInfo
    let integration: IntentIntegrationState
    let activeSession: IntentSessionSummary?
    let pendingFocusStart: IntentSessionSummary?
    let pendingFocusComplete: IntentSessionSummary?
    let pendingReview: IntentPendingReview?
    let pendingReviewsCount: Int
}

struct IntentDashboardState: Decodable {
    let generatedAt: Int
    let recentSessions: [IntentDashboardSession]
}

struct IntentMetricsState: Decodable {
    let generatedAt: Int
    let windowDays: Int
    let reviewedSessions: Int
    let completedSessions: Int
    let pendingReviews: Int
    let reviewCompletionRate: Double
    let averageDurationMs: Double
    let averageDistractions: Double
    let qualityScore: Double
    let dominantCategory: String?
    let streakDays: Int
    let signalAverages: [IntentSignalAverage]
    let signalDailySeries: [IntentSignalDailyPoint]?
    let dailyDurationSeries: [IntentDailyDurationPoint]?
    let categoryBreakdown: [IntentCategoryBreakdown]
    let trendSeries: [IntentMetricTrendPoint]
    let dailyVolume: [IntentDailyVolumePoint]
    let reflectionHighlights: [IntentReflectionHighlight]
    let lastReviewedAt: Int?
    let lastUpdatedAt: Int?
}

struct IntentDailyReportCategory: Codable, Equatable, Identifiable {
    let id: String
    let label: String
    let count: Int
}

struct IntentDailyReportContext: Codable, Equatable {
    let generatedAt: Int
    let startTimeMs: Int
    let endTimeMs: Int
    let trackedDurationMs: Int
    let totalSessions: Int
    let completedSessions: Int
    let reviewedSessions: Int
    let pendingReviews: Int
    let averageFocus: Double?
    let averageAdherence: Double?
    let averageEnergy: Double?
    let totalDistractions: Int
    let topCategories: [IntentDailyReportCategory]
    let sessions: [IntentDailyReportSession]
}

struct IntentSignalDailyPoint: Decodable, Identifiable, Equatable {
    let id: String
    let dayStart: Int
    let metrics: [String: Double]
}

struct IntentDailyDurationPoint: Decodable, Identifiable, Equatable {
    let id: String
    let dayStart: Int
    let durationMs: Double
    let sessionCount: Int
}

struct IntentSignalAverage: Decodable, Identifiable, Equatable {
    let id: String
    let key: String
    let title: String
    let average: Double
    let count: Int
    let deltaFromPrevious: Double?
}

struct IntentCategoryBreakdown: Decodable, Identifiable, Equatable {
    let id: String
    let key: String
    let label: String
    let count: Int
    let share: Double
}

struct IntentMetricTrendPoint: Decodable, Identifiable, Equatable {
    let id: String
    let sessionId: String
    let title: String
    let observedAt: Int
    let durationMs: Int
    let taskCategory: String
    let metrics: [String: Double]
}

struct IntentDailyVolumePoint: Decodable, Identifiable, Equatable {
    let id: String
    let dayStart: Int
    let reviewedCount: Int
    let averageFocus: Double?
}

struct IntentReflectionHighlight: Decodable, Identifiable, Equatable {
    let id: String
    let sessionId: String
    let title: String
    let observedAt: Int
    let taskCategory: String
    let focus: Int?
    let energy: Int?
    let distractions: Int?
    let whatWentWell: String
    let whatDidntGoWell: String
}

struct IntentDeviceInfo: Decodable {
    let id: String
    let name: String
    let platform: String
    let isDefault: Bool
    let autoStartFocus: Bool
    let autoCompleteFocus: Bool
    let autoShowReview: Bool
    let startShortcutName: String?
    let completeShortcutName: String?
    let lastSeenAt: Int?
}

struct IntentIntegrationState: Decodable {
    let defaultDeviceId: String?
    let togglWorkspaceId: Int?
    let togglWebhookSubscriptionId: Int?
    let togglWebhookUrl: String?
    let togglWebhookValidatedAt: Int?
    let lastWebhookAt: Int?
    let lastWebhookAction: String?
    let lastWebhookTimeEntryId: String?
    let lastWebhookError: String?
}

struct IntentSessionSummary: Decodable, Identifiable, Equatable {
    let id: String
    let source: String
    let sourceTimeEntryId: String
    let workspaceId: Int
    let togglUserId: Int?
    let togglProjectId: Int?
    let projectName: String?
    let togglTaskId: Int?
    let description: String
    let tags: [String]
    let billable: Bool?
    let startTimeMs: Int
    let stopTimeMs: Int?
    let durationMs: Int?
    let status: String
    let focusStatus: String
    let reviewStatus: String
    let sourceUpdatedAt: Int
    let createdAt: Int
    let updatedAt: Int

    var displayTitle: String {
        description.isEmpty ? "Untitled session" : description
    }
}

struct IntentExistingReview: Codable, Equatable {
    let numericMetrics: [String: Int]
    let countMetrics: [String: Int]
    let booleanMetrics: [String: Bool]
    let taskCategory: String
    let whatWentWell: String
    let whatDidntGoWell: String

    func numericMetric(_ key: String) -> Int? {
        numericMetrics[key]
    }

    func countMetric(_ key: String) -> Int? {
        countMetrics[key]
    }
}

struct IntentPendingReview: Decodable, Identifiable, Equatable {
    let id: String
    let source: String
    let sourceTimeEntryId: String
    let workspaceId: Int
    let togglUserId: Int?
    let togglProjectId: Int?
    let projectName: String?
    let togglTaskId: Int?
    let description: String
    let tags: [String]
    let billable: Bool?
    let startTimeMs: Int
    let stopTimeMs: Int?
    let durationMs: Int?
    let status: String
    let focusStatus: String
    let reviewStatus: String
    let sourceUpdatedAt: Int
    let createdAt: Int
    let updatedAt: Int
    let existingReview: IntentExistingReview?

    var displayTitle: String {
        description.isEmpty ? "Untitled session" : description
    }
}

struct IntentDashboardSession: Decodable, Identifiable, Equatable {
    let id: String
    let source: String
    let sourceTimeEntryId: String
    let workspaceId: Int
    let togglUserId: Int?
    let togglProjectId: Int?
    let projectName: String?
    let togglTaskId: Int?
    let description: String
    let tags: [String]
    let billable: Bool?
    let startTimeMs: Int
    let stopTimeMs: Int?
    let durationMs: Int?
    let status: String
    let focusStatus: String
    let reviewStatus: String
    let sourceUpdatedAt: Int
    let createdAt: Int
    let updatedAt: Int
    let existingReview: IntentExistingReview?

    var displayTitle: String {
        description.isEmpty ? "Untitled session" : description
    }
}

struct IntentDailyReportSession: Codable, Identifiable, Equatable {
    let id: String
    let source: String
    let sourceTimeEntryId: String
    let workspaceId: Int
    let togglUserId: Int?
    let togglProjectId: Int?
    let projectName: String?
    let togglTaskId: Int?
    let description: String
    let tags: [String]
    let billable: Bool?
    let startTimeMs: Int
    let stopTimeMs: Int?
    let durationMs: Int?
    let durationWithinWindowMs: Int
    let status: String
    let focusStatus: String
    let reviewStatus: String
    let sourceUpdatedAt: Int
    let createdAt: Int
    let updatedAt: Int
    let existingReview: IntentExistingReview?

    var displayTitle: String {
        description.isEmpty ? "Untitled session" : description
    }
}

struct IntentGeneratedDailyReport: Codable, Equatable, Identifiable {
    enum Source: String, Codable {
        case ai
        case fallback
    }

    let id: String
    let dayKey: String
    let title: String
    let headline: String
    let overview: String
    let stats: [String]
    let whatWentWell: [String]
    let whatDidntGoWell: [String]
    let improvements: [String]
    let intervalStartMs: Int
    let intervalEndMs: Int
    let generatedAtMs: Int
    let source: Source

    var generatedAtDate: Date {
        Date(timeIntervalSince1970: TimeInterval(generatedAtMs) / 1000)
    }

    var intervalStartDate: Date {
        Date(timeIntervalSince1970: TimeInterval(intervalStartMs) / 1000)
    }

    var intervalEndDate: Date {
        Date(timeIntervalSince1970: TimeInterval(intervalEndMs) / 1000)
    }
}

struct IntentReviewDraft: Equatable {
    var numericMetrics = [String: Int]()
    var countMetrics = [String: Int]()
    var booleanMetrics = [String: Bool]()
    var taskCategory = IntentReviewCatalog.defaultTaskCategory
    var projectName = ""
    var whatWentWell = ""
    var whatDidntGoWell = ""

    init(existingReview: IntentExistingReview?, sessionProjectName: String? = nil) {
        guard let existingReview else {
            if let name = sessionProjectName, !name.isEmpty {
                self.projectName = name
            }
            return
        }

        if let name = sessionProjectName, !name.isEmpty {
            self.projectName = name
        }

        taskCategory = existingReview.taskCategory
        numericMetrics.merge(existingReview.numericMetrics) { _, new in new }
        countMetrics.merge(existingReview.countMetrics) { _, new in new }
        booleanMetrics = existingReview.booleanMetrics
        whatWentWell = existingReview.whatWentWell
        whatDidntGoWell = existingReview.whatDidntGoWell
    }

    mutating func setSessionProjectNameIfNeeded(_ name: String?) {
        if let name = name, projectName.isEmpty {
            projectName = name
        }
    }

    func numericMetricValue(for key: String) -> Int {
        numericMetrics[key] ?? IntentReviewCatalog.defaultNumericValue
    }

    mutating func setNumericMetricValue(_ value: Int, for key: String) {
        numericMetrics[key] = min(10, max(0, value))
    }

    func countMetricValue(for key: String) -> Int {
        countMetrics[key] ?? 0
    }

    mutating func setCountMetricValue(_ value: Int, for key: String) {
        countMetrics[key] = max(0, value)
    }

    mutating func apply(_ patch: IntentReviewAIPatch) {
        if let taskCategory = patch.taskCategory?.trimmingCharacters(in: .whitespacesAndNewlines),
           !taskCategory.isEmpty {
            self.taskCategory = taskCategory
        }

        for (key, value) in patch.numericMetrics {
            setNumericMetricValue(value, for: key)
        }

        for (key, value) in patch.countMetrics {
            setCountMetricValue(value, for: key)
        }

        for (key, value) in patch.booleanMetrics {
            booleanMetrics[key] = value
        }

        if let whatWentWell = patch.whatWentWell?.trimmingCharacters(in: .whitespacesAndNewlines),
           !whatWentWell.isEmpty {
            self.whatWentWell = Self.merge(existing: self.whatWentWell, incoming: whatWentWell)
        }

        if let whatDidntGoWell = patch.whatDidntGoWell?.trimmingCharacters(in: .whitespacesAndNewlines),
           !whatDidntGoWell.isEmpty {
            self.whatDidntGoWell = Self.merge(existing: self.whatDidntGoWell, incoming: whatDidntGoWell)
        }
    }

    private static func merge(existing: String, incoming: String) -> String {
        let trimmedExisting = existing.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedIncoming = incoming.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedIncoming.isEmpty else {
            return trimmedExisting
        }

        guard !trimmedExisting.isEmpty else {
            return trimmedIncoming
        }

        guard trimmedExisting != trimmedIncoming else {
            return trimmedExisting
        }

        return "\(trimmedExisting)\n\n\(trimmedIncoming)"
    }

    var hasMeaningfulContent: Bool {
        if !taskCategory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }

        if !numericMetrics.isEmpty || !countMetrics.isEmpty || !booleanMetrics.isEmpty {
            return true
        }

        if !whatWentWell.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }

        if !whatDidntGoWell.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }

        return false
    }
}

struct IntentReviewContext: Identifiable, Equatable {
    let session: IntentPendingReview
    var draft: IntentReviewDraft

    var id: String {
        session.id
    }
}

struct IntentAPIError: Decodable {
    let error: String
}

struct IntentReviewMetricDefinition: Identifiable, Hashable {
    let id: String
    let title: String
}

enum IntentReviewCatalog {
    nonisolated static let defaultNumericValue = 5
    nonisolated static let defaultTaskCategory = ""

    nonisolated static let numericMetricDefinitions: [IntentReviewMetricDefinition] = [
        IntentReviewMetricDefinition(id: "mindfulness", title: "Mindfulness"),
        IntentReviewMetricDefinition(id: "discipline", title: "Discipline"),
//        IntentReviewMetricDefinition(id: "engagement", title: "Engagement"),
        IntentReviewMetricDefinition(id: "focus", title: "Focus"),
//        IntentReviewMetricDefinition(id: "courage", title: "Courage"),
//        IntentReviewMetricDefinition(id: "authenticity", title: "Authenticity"),
        IntentReviewMetricDefinition(id: "purpose", title: "Purpose"),
        IntentReviewMetricDefinition(id: "energy", title: "Energy"),
//        IntentReviewMetricDefinition(id: "communication", title: "Communication"),
//        IntentReviewMetricDefinition(id: "uniqueness", title: "Uniqueness"),
//        IntentReviewMetricDefinition(id: "adherence", title: "Adherence"),
        IntentReviewMetricDefinition(id: "intentionality", title: "Intentionality"),
    ]

    nonisolated static let countMetricDefinitions: [IntentReviewMetricDefinition] = [
        IntentReviewMetricDefinition(id: "distractions", title: "Distractions"),
    ]

    nonisolated static let defaultNumericMetrics = Dictionary(
        uniqueKeysWithValues: numericMetricDefinitions.map { ($0.id, defaultNumericValue) }
    )

    nonisolated static let defaultCountMetrics = Dictionary(
        uniqueKeysWithValues: countMetricDefinitions.map { ($0.id, 0) }
    )

    nonisolated static func title(for key: String) -> String {
        if let metric = numericMetricDefinitions.first(where: { $0.id == key }) {
            return metric.title
        }

        if let metric = countMetricDefinitions.first(where: { $0.id == key }) {
            return metric.title
        }

        return key
    }
}
