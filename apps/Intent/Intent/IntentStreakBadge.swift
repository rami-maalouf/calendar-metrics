//
//  IntentStreakBadge.swift
//  Intent
//
//  Time-tracking streak, computed client-side from the daily duration series.
//  A day counts when at least one completed session was tracked. A streak
//  anchored on yesterday stays alive (shown at risk) until today is tracked,
//  so it never resets to zero at midnight before the day has started.
//

import SwiftUI

struct IntentTrackingStreak: Equatable {
    let days: Int
    let isAliveToday: Bool
    let cappedByWindow: Bool

    var isAtRisk: Bool {
        days > 0 && !isAliveToday
    }

    static func compute(
        from series: [IntentDailyDurationPoint],
        windowDays: Int,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> IntentTrackingStreak {
        let trackedDays = Set(
            series
                .filter { $0.durationMs > 0 }
                .map { calendar.startOfDay(for: Date(timeIntervalSince1970: TimeInterval($0.dayStart) / 1000)) }
        )

        let today = calendar.startOfDay(for: now)
        let isAliveToday = trackedDays.contains(today)

        var cursor = isAliveToday
            ? today
            : calendar.date(byAdding: .day, value: -1, to: today) ?? today
        var days = 0
        while trackedDays.contains(cursor) {
            days += 1
            cursor = calendar.date(byAdding: .day, value: -1, to: cursor) ?? cursor
        }

        // the fetch only covers the selected window; if the chain runs all the
        // way back to its first day, the real streak may be longer
        let windowStart = calendar.date(byAdding: .day, value: -windowDays, to: today) ?? today
        let chainStart = calendar.date(byAdding: .day, value: 1, to: cursor) ?? cursor
        let cappedByWindow = days > 0 && chainStart <= windowStart

        return IntentTrackingStreak(
            days: days,
            isAliveToday: isAliveToday,
            cappedByWindow: cappedByWindow
        )
    }
}

struct IntentStreakBadge: View {
    let streak: IntentTrackingStreak

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "flame.fill")
                .font(.system(size: 19, weight: .bold))
                .foregroundStyle(flameStyle)
                .opacity(streak.isAtRisk ? 0.55 : 1)
                .symbolEffect(.pulse, options: .repeating, isActive: streak.isAtRisk)

            VStack(alignment: .leading, spacing: 1) {
                Text(headline)
                    .font(.system(size: 15, weight: .heavy, design: .rounded))

                Text(caption)
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            Capsule(style: .continuous)
                .fill(washColor)
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                )
        )
    }

    private var headline: String {
        guard streak.days > 0 else {
            return "No streak"
        }
        let count = streak.cappedByWindow ? "\(streak.days)+" : "\(streak.days)"
        return "\(count)-day streak"
    }

    private var caption: String {
        if streak.days == 0 {
            return "track a session to ignite it"
        }
        return streak.isAliveToday ? "tracked today" : "track today to keep it"
    }

    // the flame heats up as the streak grows
    private var flameStyle: LinearGradient {
        let colors: [Color]
        switch streak.days {
        case 0:
            colors = [Color.gray.opacity(0.6), Color.gray.opacity(0.4)]
        case 1..<7:
            colors = [.orange, .yellow]
        case 7..<30:
            colors = [.red, .orange]
        case 30..<100:
            colors = [Color(red: 0.85, green: 0.1, blue: 0.3), .orange]
        default:
            colors = [.blue, .cyan]
        }
        return LinearGradient(colors: colors, startPoint: .bottom, endPoint: .top)
    }

    private var washColor: Color {
        streak.days > 0 ? Color.orange.opacity(0.1) : Color.primary.opacity(0.05)
    }
}
