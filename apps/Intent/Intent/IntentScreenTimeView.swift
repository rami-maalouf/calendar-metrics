//
//  IntentScreenTimeView.swift
//  Intent
//
//  dedicated iphone screen-time page for macos.
//

import Charts
import SwiftUI

struct IntentScreenTimeView: View {
    @ObservedObject var model: IntentAppModel
    @State private var selectedHour: Int?

    private var days: [IntentScreenDay] { model.screenDays }
    private var day: IntentScreenDay? { model.screenDay }
    private var hue: Color { VisualsPalette.hue(for: "screenTime") }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header

                if let day {
                    dayPicker
                    hero(day)
                    statsRow(day)
                    HStack(alignment: .top, spacing: 18) {
                        hourlyPanel(day)
                            .frame(maxWidth: .infinity)
                        topAppsPanel(day)
                            .frame(width: 320)
                    }
                    if let selectedHour,
                       let hour = day.hours?.first(where: { $0.hourOfDay == selectedHour })
                    {
                        hourDetail(hour)
                    }
                    if days.count >= 2 {
                        HStack(alignment: .top, spacing: 18) {
                            trendPanel
                                .frame(maxWidth: .infinity)
                            weekdayPanel
                                .frame(maxWidth: .infinity)
                        }
                    }
                } else {
                    VisualsPanel {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("No iPhone screen data yet")
                                .font(.system(size: 22, weight: .bold, design: .rounded))
                            Text("Run the Biome collector or wait for the 8:05 AM launchd job.")
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 40)
                    }
                }
            }
            .padding(28)
        }
        .task {
            await model.refreshScreenNow()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("iPhone Screen")
                .font(.system(size: 34, weight: .black, design: .rounded))
            Text("Daily phone usage from Biome App.InFocus")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
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
                        VStack(alignment: .leading, spacing: 4) {
                            Text(shortDayLabel(row.dayKey))
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                            Text(hoursLabel(row.totalSeconds / 3600.0))
                                .font(.system(size: 16, weight: .heavy, design: .rounded))
                                .monospacedDigit()
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(selected ? hue.opacity(0.18) : Color.clear)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(selected ? hue.opacity(0.7) : Color.primary.opacity(0.08), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func hero(_ day: IntentScreenDay) -> some View {
        let previous = previousDay(before: day.dayKey)
        let deltaHours = previous.map { ($0.totalSeconds == 0 ? 0 : day.totalSeconds - $0.totalSeconds) / 3600.0 }

        return VisualsPanel {
            HStack(alignment: .firstTextBaseline, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(day.dayKey)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                    Text(hoursLabel(day.totalSeconds / 3600.0))
                        .font(.system(size: 56, weight: .heavy, design: .rounded))
                    Text(day.notificationBody)
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer()

                if let deltaHours, let previous {
                    VStack(alignment: .trailing, spacing: 6) {
                        Text("vs \(previous.dayKey)")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)
                        Text((deltaHours >= 0 ? "+" : "") + hoursLabel(abs(deltaHours)))
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .foregroundStyle(deltaHours >= 0 ? VisualsPalette.deltaBad : VisualsPalette.deltaGood)
                    }
                }
            }
        }
    }

    private func statsRow(_ day: IntentScreenDay) -> some View {
        let avg7 = averageHours(Array(days.suffix(7)))
        let peak = peakHour(day)
        let top = day.topApps.first
        let share = top.map { day.totalSeconds > 0 ? Int((($0.seconds / day.totalSeconds) * 100).rounded()) : 0 } ?? 0

        return HStack(spacing: 14) {
            screenStatCard(title: "7-day avg", value: hoursLabel(avg7), caption: "daily mean")
            screenStatCard(
                title: "Peak hour",
                value: peak.map { String(format: "%02d:00", $0.hour) } ?? "—",
                caption: peak.map { hoursLabel($0.seconds / 3600.0) } ?? "no data"
            )
            screenStatCard(title: "Apps", value: "\(day.topApps.count)", caption: "in top rollup")
            screenStatCard(
                title: "Top app",
                value: top.map { hoursLabel($0.seconds / 3600.0) } ?? "—",
                caption: top.map { "\($0.title) · \(share)%" } ?? "none"
            )
        }
    }

    private func screenStatCard(title: String, value: String, caption: String) -> some View {
        VisualsPanel {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.system(size: 28, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(caption)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func hourlyPanel(_ day: IntentScreenDay) -> some View {
        let points = day.hourlyTotals.enumerated().map { (hour: $0.offset, hours: $0.element / 3600.0) }

        return VisualsPanel {
            VStack(alignment: .leading, spacing: 12) {
                Text("Hourly breakdown")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)

                Chart(points, id: \.hour) { point in
                    BarMark(
                        x: .value("Hour", point.hour),
                        y: .value("Hours", point.hours)
                    )
                    .foregroundStyle(selectedHour == point.hour ? Color.accentColor.gradient : hue.gradient)
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
                .frame(height: 220)
            }
        }
    }

    private func topAppsPanel(_ day: IntentScreenDay) -> some View {
        VisualsPanel {
            VStack(alignment: .leading, spacing: 12) {
                Text("Top apps")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)

                ForEach(Array(day.topApps.prefix(8).enumerated()), id: \.element.bundleId) { _, app in
                    let share = day.totalSeconds > 0 ? app.seconds / day.totalSeconds : 0
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(app.title)
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                                .lineLimit(1)
                            Spacer()
                            Text(hoursLabel(app.seconds / 3600.0))
                                .font(.system(size: 13, weight: .bold, design: .rounded))
                                .monospacedDigit()
                        }
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.primary.opacity(0.06))
                                Capsule()
                                    .fill(hue.gradient)
                                    .frame(width: max(8, geo.size.width * share))
                            }
                        }
                        .frame(height: 7)
                    }
                }
            }
        }
    }

    private func hourDetail(_ hour: IntentScreenHour) -> some View {
        VisualsPanel {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(String(format: "Hour %02d", hour.hourOfDay))
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                    Spacer()
                    Text(hoursLabel(hour.totalSeconds / 3600.0))
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .monospacedDigit()
                }

                HStack(alignment: .top, spacing: 18) {
                    ForEach(Array(hour.topApps.prefix(5).enumerated()), id: \.element.bundleId) { _, app in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(app.title)
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                            Text(hoursLabel(app.seconds / 3600.0))
                                .font(.system(size: 18, weight: .bold, design: .rounded))
                                .monospacedDigit()
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    private var trendPanel: some View {
        let points = days.suffix(21).compactMap { row -> VisualsDayPoint? in
            guard let date = Self.dayKeyFormatter.date(from: row.dayKey) else { return nil }
            return VisualsDayPoint(day: date, value: row.totalSeconds / 3600.0)
        }

        return VisualsPanel {
            VStack(alignment: .leading, spacing: 12) {
                Text("Daily trend")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                CountChart(points: points, hue: hue)
                    .frame(height: 180)
            }
        }
    }

    private var weekdayPanel: some View {
        let points = weekdayAverages(days)

        return VisualsPanel {
            VStack(alignment: .leading, spacing: 12) {
                Text("Weekday rhythm")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)

                Chart(points) { point in
                    BarMark(
                        x: .value("Weekday", point.label),
                        y: .value("Hours", point.hours)
                    )
                    .foregroundStyle((point.isWeekend ? VisualsPalette.deltaBad : hue).gradient)
                    .cornerRadius(4)
                }
                .frame(height: 180)
            }
        }
    }

    private func previousDay(before dayKey: String) -> IntentScreenDay? {
        guard let index = days.firstIndex(where: { $0.dayKey == dayKey }), index > 0 else {
            return nil
        }
        return days[index - 1]
    }

    private func averageHours(_ rows: [IntentScreenDay]) -> Double {
        guard !rows.isEmpty else { return 0 }
        return rows.map { $0.totalSeconds / 3600.0 }.reduce(0, +) / Double(rows.count)
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
        guard let date = Self.dayKeyFormatter.date(from: dayKey) else { return dayKey }
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE d"
        return formatter.string(from: date)
    }

    private func weekdayAverages(_ rows: [IntentScreenDay]) -> [MacScreenWeekdayPoint] {
        var buckets: [Int: [Double]] = [:]
        for row in rows {
            guard let date = Self.dayKeyFormatter.date(from: row.dayKey) else { continue }
            let weekday = Calendar.current.component(.weekday, from: date)
            buckets[weekday, default: []].append(row.totalSeconds / 3600.0)
        }
        let labels = [1: "Sun", 2: "Mon", 3: "Tue", 4: "Wed", 5: "Thu", 6: "Fri", 7: "Sat"]
        return (1...7).map { weekday in
            let values = buckets[weekday] ?? []
            let average = values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
            return MacScreenWeekdayPoint(
                id: weekday,
                label: labels[weekday] ?? "?",
                hours: average,
                isWeekend: weekday == 1 || weekday == 7
            )
        }
    }

    private static let dayKeyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

private struct MacScreenWeekdayPoint: Identifiable {
    let id: Int
    let label: String
    let hours: Double
    let isWeekend: Bool
}
