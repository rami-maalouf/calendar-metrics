//
//  IntentScreenTimeView.swift
//  Intent
//
//  dedicated iphone screen-time dashboard for ios.
//

import Charts
import SwiftUI

struct IntentScreenTimeView: View {
    @ObservedObject var model: IntentionalityAppModel
    @State private var selectedHour: Int?

    private var days: [IntentScreenDay] {
        model.screenDays
    }

    private var day: IntentScreenDay? {
        model.screenDay
    }

    var body: some View {
        IntentScreenBackground {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header

                    if let day {
                        dayPicker
                        hero(day)
                        insightTiles(day)
                        hourlyChart(day)
                        if let selectedHour, let hour = day.hours?.first(where: { $0.hourOfDay == selectedHour }) {
                            hourDetail(hour)
                        }
                        topApps(day)
                        if days.count >= 2 {
                            trendChart
                            weekdayChart
                        }
                    } else if !days.isEmpty {
                        dayPicker
                        IntentPanel {
                            Text("Select a day to load its breakdown.")
                                .font(.subheadline)
                                .foregroundStyle(IntentTheme.textSecondary)
                        }
                    } else if model.isPaired {
                        IntentPanel {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("No iPhone screen data yet")
                                    .font(.headline)
                                    .foregroundStyle(IntentTheme.textPrimary)
                                Text("Pull to refresh after the Mac collector runs.")
                                    .font(.subheadline)
                                    .foregroundStyle(IntentTheme.textSecondary)
                            }
                        }
                    } else {
                        PairingPrompt()
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 14)
                .padding(.bottom, 28)
            }
            .refreshable {
                await model.refreshScreenDashboard(dayKey: day?.dayKey)
            }
        }
        .task {
            await model.refreshScreenDashboard(dayKey: day?.dayKey)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Screen")
                .font(.system(size: 34, weight: .black, design: .rounded))
                .foregroundStyle(IntentTheme.textPrimary)

            Text("iPhone usage from Biome")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(IntentTheme.textSecondary)
        }
    }

    private var dayPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(days.reversed()) { row in
                    let selected = row.dayKey == day?.dayKey
                    Button {
                        Task {
                            await model.selectScreenDay(row.dayKey)
                            selectedHour = nil
                        }
                    } label: {
                        VStack(spacing: 4) {
                            Text(shortDayLabel(row.dayKey))
                                .font(.caption2.weight(.bold))
                            Text(screenDurationLabel(row.totalSeconds))
                                .font(.caption.weight(.heavy))
                                .monospacedDigit()
                        }
                        .foregroundStyle(selected ? IntentTheme.textPrimary : IntentTheme.textSecondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(
                            selected ? IntentTheme.amber.opacity(0.28) : IntentTheme.panel,
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(selected ? IntentTheme.amber.opacity(0.7) : IntentTheme.border, lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func hero(_ day: IntentScreenDay) -> some View {
        let previous = previousDay(before: day.dayKey)
        let deltaSeconds = previous.map { day.totalSeconds - $0.totalSeconds }

        return IntentPanel(padding: 18) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(day.dayKey)
                            .font(.headline)
                            .foregroundStyle(IntentTheme.textPrimary)
                        Text(day.notificationBody)
                            .font(.caption)
                            .foregroundStyle(IntentTheme.textSecondary)
                            .lineLimit(2)
                    }

                    Spacer(minLength: 10)

                    Text(screenDurationLabel(day.totalSeconds))
                        .font(.system(size: 42, weight: .black, design: .rounded))
                        .foregroundStyle(IntentTheme.amber)
                        .monospacedDigit()
                }

                if let deltaSeconds, let previous {
                    HStack(spacing: 8) {
                        Text(deltaSeconds >= 0 ? "Up" : "Down")
                            .font(.caption.weight(.bold))
                        Text(screenDurationLabel(abs(deltaSeconds)))
                            .font(.caption.weight(.bold))
                            .monospacedDigit()
                        Text("vs \(previous.dayKey)")
                            .font(.caption)
                            .foregroundStyle(IntentTheme.textSecondary)
                    }
                    .foregroundStyle(deltaSeconds >= 0 ? IntentTheme.coral : IntentTheme.mint)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        (deltaSeconds >= 0 ? IntentTheme.coral : IntentTheme.mint).opacity(0.14),
                        in: Capsule()
                    )
                }
            }
        }
    }

    private func insightTiles(_ day: IntentScreenDay) -> some View {
        let avg7 = averageSeconds(days.suffix(7))
        let peak = peakHour(day)
        let top = day.topApps.first
        let share = top.map { day.totalSeconds > 0 ? ($0.seconds / day.totalSeconds) * 100 : 0 } ?? 0

        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
            MetricTile(
                title: "7-Day Avg",
                value: screenDurationLabel(avg7),
                caption: "mean daily screen time",
                systemImage: "chart.line.uptrend.xyaxis",
                tint: IntentTheme.accent
            )
            MetricTile(
                title: "Peak Hour",
                value: peak.map { String(format: "%02d:00", $0.hour) } ?? "—",
                caption: peak.map { screenDurationLabel($0.seconds) + " in that hour" } ?? "no hourly data",
                systemImage: "clock.fill",
                tint: IntentTheme.amber
            )
            MetricTile(
                title: "Apps Used",
                value: "\(day.topApps.count)",
                caption: "in today's top rollup",
                systemImage: "app.badge.fill",
                tint: IntentTheme.mint
            )
            MetricTile(
                title: "Top App",
                value: top.map { screenDurationLabel($0.seconds) } ?? "—",
                caption: top.map { "\($0.title) · \(Int(share.rounded()))%" } ?? "no apps",
                systemImage: "star.fill",
                tint: IntentTheme.coral
            )
        }
    }

    private func hourlyChart(_ day: IntentScreenDay) -> some View {
        let points = day.hourlyTotals.enumerated().map { (hour: $0.offset, hours: $0.element / 3600.0) }

        return ChartCard(title: "Hourly Breakdown", subtitle: "tap a bar for that hour's apps") {
            Chart(points, id: \.hour) { point in
                BarMark(
                    x: .value("Hour", point.hour),
                    y: .value("Hours", point.hours)
                )
                .foregroundStyle(
                    selectedHour == point.hour
                        ? IntentTheme.coral.gradient
                        : IntentTheme.amber.gradient
                )
                .cornerRadius(3)
            }
            .chartXScale(domain: 0...23)
            .chartXSelection(value: $selectedHour)
            .chartXAxis {
                AxisMarks(values: [0, 6, 12, 18, 23]) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let hour = value.as(Int.self) {
                            Text(String(format: "%02d", hour))
                        }
                    }
                }
            }
            .frame(height: 200)
        }
    }

    private func hourDetail(_ hour: IntentScreenHour) -> some View {
        IntentPanel {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(String(format: "%02d:00 – %02d:59", hour.hourOfDay, hour.hourOfDay))
                        .font(.headline)
                        .foregroundStyle(IntentTheme.textPrimary)
                    Spacer()
                    Text(screenDurationLabel(hour.totalSeconds))
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(IntentTheme.amber)
                }

                ForEach(Array(hour.topApps.prefix(5).enumerated()), id: \.element.bundleId) { index, app in
                    HStack {
                        Text("\(index + 1). \(app.title)")
                            .font(.subheadline)
                            .foregroundStyle(IntentTheme.textPrimary)
                            .lineLimit(1)
                        Spacer()
                        Text(screenDurationLabel(app.seconds))
                            .font(.subheadline.weight(.semibold).monospacedDigit())
                            .foregroundStyle(IntentTheme.textSecondary)
                    }
                }
            }
        }
    }

    private func topApps(_ day: IntentScreenDay) -> some View {
        IntentPanel {
            VStack(alignment: .leading, spacing: 12) {
                Text("Top Apps")
                    .font(.headline)
                    .foregroundStyle(IntentTheme.textPrimary)

                ForEach(Array(day.topApps.prefix(8).enumerated()), id: \.element.bundleId) { _, app in
                    let share = day.totalSeconds > 0 ? app.seconds / day.totalSeconds : 0
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(app.title)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(IntentTheme.textPrimary)
                                .lineLimit(1)
                            Spacer()
                            Text(screenDurationLabel(app.seconds))
                                .font(.subheadline.weight(.bold).monospacedDigit())
                                .foregroundStyle(IntentTheme.amber)
                        }

                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(IntentTheme.panelStrong)
                                Capsule()
                                    .fill(IntentTheme.amber.gradient)
                                    .frame(width: max(6, geo.size.width * share))
                            }
                        }
                        .frame(height: 8)
                    }
                }
            }
        }
    }

    private var trendChart: some View {
        let points = days.suffix(21).map { (dayKey: $0.dayKey, hours: $0.totalSeconds / 3600.0) }

        return ChartCard(title: "Daily Trend", subtitle: "last \(points.count) days") {
            Chart {
                ForEach(Array(points.enumerated()), id: \.offset) { _, point in
                    AreaMark(
                        x: .value("Day", point.dayKey),
                        y: .value("Hours", point.hours)
                    )
                    .foregroundStyle(IntentTheme.amber.opacity(0.16).gradient)
                    .interpolationMethod(.catmullRom)

                    LineMark(
                        x: .value("Day", point.dayKey),
                        y: .value("Hours", point.hours)
                    )
                    .foregroundStyle(IntentTheme.amber)
                    .lineStyle(StrokeStyle(lineWidth: 2.4))
                    .interpolationMethod(.catmullRom)
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                    AxisValueLabel(collisionResolution: .greedy)
                }
            }
            .frame(height: 180)
        }
    }

    private var weekdayChart: some View {
        let points = weekdayAverages(days)

        return ChartCard(title: "Weekday Rhythm", subtitle: "average hours by weekday") {
            Chart {
                ForEach(points) { point in
                    BarMark(
                        x: .value("Weekday", point.label),
                        y: .value("Hours", point.hours)
                    )
                    .foregroundStyle((point.isWeekend ? IntentTheme.coral : IntentTheme.accent).gradient)
                    .cornerRadius(4)
                }
            }
            .frame(height: 180)
        }
    }

    private func previousDay(before dayKey: String) -> IntentScreenDay? {
        guard let index = days.firstIndex(where: { $0.dayKey == dayKey }), index > 0 else {
            return nil
        }
        return days[index - 1]
    }

    private func averageSeconds<S: Sequence>(_ rows: S) -> Double where S.Element == IntentScreenDay {
        let values = Array(rows)
        guard !values.isEmpty else { return 0 }
        return values.map(\.totalSeconds).reduce(0, +) / Double(values.count)
    }

    private func peakHour(_ day: IntentScreenDay) -> (hour: Int, seconds: Double)? {
        guard let maxSeconds = day.hourlyTotals.max(), maxSeconds > 0,
              let hour = day.hourlyTotals.firstIndex(of: maxSeconds)
        else {
            return nil
        }
        return (hour, maxSeconds)
    }

    private func shortDayLabel(_ dayKey: String) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: dayKey) else { return dayKey }
        formatter.dateFormat = "EEE d"
        return formatter.string(from: date)
    }

    private func weekdayAverages(_ rows: [IntentScreenDay]) -> [ScreenWeekdayPoint] {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"

        var buckets: [Int: [Double]] = [:]
        for row in rows {
            guard let date = formatter.date(from: row.dayKey) else { continue }
            let weekday = Calendar.current.component(.weekday, from: date)
            buckets[weekday, default: []].append(row.totalSeconds / 3600.0)
        }

        let labels = [1: "Sun", 2: "Mon", 3: "Tue", 4: "Wed", 5: "Thu", 6: "Fri", 7: "Sat"]
        return (1...7).map { weekday in
            let values = buckets[weekday] ?? []
            let average = values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
            return ScreenWeekdayPoint(
                id: weekday,
                label: labels[weekday] ?? "?",
                hours: average,
                isWeekend: weekday == 1 || weekday == 7
            )
        }
    }
}

private struct ScreenWeekdayPoint: Identifiable {
    let id: Int
    let label: String
    let hours: Double
    let isWeekend: Bool
}

func screenDurationLabel(_ seconds: Double) -> String {
    let totalMinutes = Int((seconds / 60.0).rounded())
    if totalMinutes < 60 {
        return "\(max(totalMinutes, 0))m"
    }
    let hours = Double(totalMinutes) / 60.0
    if hours >= 10 || totalMinutes % 60 == 0 {
        return String(format: "%.0fh", hours)
    }
    return String(format: "%.1fh", hours)
}
