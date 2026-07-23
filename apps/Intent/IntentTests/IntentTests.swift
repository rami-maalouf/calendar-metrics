//
//  IntentTests.swift
//  IntentTests
//
//  Created by Rami Maalouf on 2026-03-10.
//

import Foundation
import Testing
@testable import Intent

struct IntentTests {
    @MainActor
    @Test func dailyReportWindowUsesConfiguredLateNightBoundary() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        let now = calendar.date(from: DateComponents(year: 2026, month: 3, day: 16, hour: 1, minute: 30))!
        let window = IntentDailyReportScheduler.mostRecentCompletedWindow(
            relativeTo: now,
            minutesAfterMidnight: 120,
            calendar: calendar
        )

        #expect(window.dayKey == "2026-03-14")
        #expect(window.startDate == calendar.date(from: DateComponents(year: 2026, month: 3, day: 14, hour: 2, minute: 0))!)
        #expect(window.endDate == calendar.date(from: DateComponents(year: 2026, month: 3, day: 15, hour: 2, minute: 0))!)
    }

    @MainActor
    @Test func intentDayTreatsEarlyMorningAsPreviousDay() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        let twoAM = calendar.date(from: DateComponents(year: 2026, month: 3, day: 16, hour: 2, minute: 15))!
        let threeFiftyNine = calendar.date(from: DateComponents(year: 2026, month: 3, day: 16, hour: 3, minute: 59))!
        let fourAM = calendar.date(from: DateComponents(year: 2026, month: 3, day: 16, hour: 4, minute: 0))!
        let noon = calendar.date(from: DateComponents(year: 2026, month: 3, day: 16, hour: 12, minute: 0))!
        let previousAfternoon = calendar.date(from: DateComponents(year: 2026, month: 3, day: 15, hour: 22, minute: 0))!

        #expect(IntentDay.dayKey(for: twoAM, calendar: calendar) == "2026-03-15")
        #expect(IntentDay.dayKey(for: threeFiftyNine, calendar: calendar) == "2026-03-15")
        #expect(IntentDay.dayKey(for: fourAM, calendar: calendar) == "2026-03-16")
        #expect(IntentDay.dayKey(for: noon, calendar: calendar) == "2026-03-16")
        #expect(IntentDay.isSameDay(twoAM, previousAfternoon, calendar: calendar))
        #expect(!IntentDay.isSameDay(twoAM, fourAM, calendar: calendar))
        #expect(
            IntentDay.start(of: twoAM, calendar: calendar) ==
                calendar.date(from: DateComponents(year: 2026, month: 3, day: 15, hour: 4, minute: 0))!
        )
        #expect(
            IntentDay.end(of: twoAM, calendar: calendar) ==
                calendar.date(from: DateComponents(year: 2026, month: 3, day: 16, hour: 4, minute: 0))!
        )
    }

    @MainActor
    @Test func fallbackReportBuilderProducesConcreteSections() async throws {
        let review = IntentExistingReview(
            numericMetrics: ["focus": 8, "adherence": 7, "energy": 6],
            countMetrics: ["distractions": 1],
            booleanMetrics: [:],
            taskCategory: "writing",
            whatWentWell: "The drafting block stayed clean because the scope was narrow.",
            whatDidntGoWell: "The final handoff slipped because I checked messages mid-block."
        )

        let session = IntentDailyReportSession(
            id: "session-1",
            source: "toggl",
            sourceTimeEntryId: "source-1",
            workspaceId: 1,
            togglUserId: nil,
            togglProjectId: nil,
            togglTaskId: nil,
            description: "Ship draft",
            tags: ["writing"],
            billable: nil,
            startTimeMs: 1_763_082_000_000,
            stopTimeMs: 1_763_085_600_000,
            durationMs: 3_600_000,
            durationWithinWindowMs: 3_600_000,
            status: "completed",
            focusStatus: "completed",
            reviewStatus: "submitted",
            sourceUpdatedAt: 1_763_085_600_000,
            createdAt: 1_763_082_000_000,
            updatedAt: 1_763_085_600_000,
            existingReview: review
        )

        let context = IntentDailyReportContext(
            generatedAt: 1_763_090_000_000,
            startTimeMs: 1_763_078_400_000,
            endTimeMs: 1_763_164_800_000,
            trackedDurationMs: 3_600_000,
            totalSessions: 1,
            completedSessions: 1,
            reviewedSessions: 1,
            pendingReviews: 0,
            averageFocus: 8,
            averageAdherence: 7,
            averageEnergy: 6,
            totalDistractions: 1,
            topCategories: [
                IntentDailyReportCategory(id: "writing", label: "writing", count: 1)
            ],
            sessions: [session]
        )

        let window = IntentDailyReportWindow(
            dayKey: "2026-03-15",
            startDate: Date(timeIntervalSince1970: 1_763_078_400),
            endDate: Date(timeIntervalSince1970: 1_763_164_800)
        )

        let payload = IntentDailyReportFallbackBuilder.build(context: context, window: window)

        #expect(!payload.headline.isEmpty)
        #expect(!payload.overview.isEmpty)
        #expect(!payload.whatWentWell.isEmpty)
        #expect(!payload.whatDidntGoWell.isEmpty)
        #expect(!payload.improvements.isEmpty)
    }
}
