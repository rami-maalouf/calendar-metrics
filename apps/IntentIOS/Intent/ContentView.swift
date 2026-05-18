//
//  ContentView.swift
//  Intent
//
//  Created by Codex on 2026-05-11.
//

import Charts
import SwiftUI

private enum IntentTab: String, Hashable {
    case home
    case trends
    case settings
    case record
}

struct ContentView: View {
    @ObservedObject var model: IntentionalityAppModel
    @State private var selectedTab: IntentTab = .home
    @State private var showingManualEntry = false

    var body: some View {
        TabView(
            selection: Binding(
                get: { selectedTab },
                set: { nextTab in
                    if nextTab == .record {
                        showingManualEntry = true
                    } else {
                        selectedTab = nextTab
                    }
                }
            )
        ) {
            IntentionalityHomeView(model: model)
                .tag(IntentTab.home)
                .tabItem {
                    Label("Home", systemImage: "house.fill")
                }

            IntentionalityTrendsView(model: model)
                .tag(IntentTab.trends)
                .tabItem {
                    Label("Trends", systemImage: "chart.xyaxis.line")
                }

            IntentionalitySettingsView(model: model)
                .tag(IntentTab.settings)
                .tabItem {
                    Label("Settings", systemImage: "gearshape.fill")
                }

            Color.clear
                .tag(IntentTab.record)
                .tabItem {
                    Label("Record", systemImage: "plus.circle.fill")
                }
        }
        .tint(IntentTheme.accent)
        .onAppear {
            model.start()
        }
        .sheet(isPresented: $showingManualEntry) {
            ManualEntrySheet(model: model)
                .presentationDetents([.height(310), .medium])
                .presentationDragIndicator(.visible)
        }
    }
}

private struct IntentionalityHomeView: View {
    @ObservedObject var model: IntentionalityAppModel

    var body: some View {
        IntentScreenBackground {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HeaderView(model: model)

                    if !model.isPaired && !model.configuration.sampleDataEnabled {
                        PairingPrompt()
                    }

                    if let snapshot = model.snapshot {
                        TodaySignalComparisonChart(snapshot: snapshot)
                        ScoreSummaryHero(snapshot: snapshot)
                        IntentInsightPillRow(items: homeInsightItems(snapshot: snapshot))
                        TodaySnapshotGrid(snapshot: snapshot)
                        TodayHourStrip(snapshot: snapshot)
                        RecentEntriesList(snapshot: snapshot)
                    } else {
                        LoadingPanel(isPaired: model.isPaired)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 14)
                .padding(.bottom, 28)
            }
        }
    }
}

private struct IntentionalityTrendsView: View {
    @ObservedObject var model: IntentionalityAppModel
    private let horizontalPadding: CGFloat = 18

    var body: some View {
        IntentScreenBackground {
            GeometryReader { geometry in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("Trends")
                                    .font(.system(size: 34, weight: .black, design: .rounded))
                                    .foregroundStyle(IntentTheme.textPrimary)

                                Text("Hourly intentionality")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(IntentTheme.textSecondary)
                            }

                            Spacer(minLength: 12)

                            WindowPicker(model: model)
                                .frame(maxWidth: 190)
                        }

                        if let snapshot = model.snapshot {
                            IntentInsightPillRow(items: trendInsightItems(snapshot: snapshot))
                            DailyAverageChart(snapshot: snapshot)
                            SevenDayMovingAverageChart(snapshot: snapshot)
                            DayOfWeekChart(snapshot: snapshot)
                            HourOfDayChart(snapshot: snapshot)
                            CorrelationInsightsCard(snapshot: snapshot)
                        } else {
                            LoadingPanel(isPaired: model.isPaired)
                        }
                    }
                    .frame(width: max(0, geometry.size.width - horizontalPadding * 2), alignment: .leading)
                    .padding(.horizontal, horizontalPadding)
                    .padding(.top, 14)
                    .padding(.bottom, 28)
                }
            }
        }
    }
}

private struct IntentionalitySettingsView: View {
    @ObservedObject var model: IntentionalityAppModel

    var body: some View {
        IntentScreenBackground {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Settings")
                            .font(.system(size: 34, weight: .black, design: .rounded))
                            .foregroundStyle(IntentTheme.textPrimary)

                        Text(model.connectionStatus)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(IntentTheme.textSecondary)
                    }

                    IntentPanel {
                        VStack(alignment: .leading, spacing: 14) {
                            LabeledInput(
                                title: "Backend URL",
                                text: Binding(
                                    get: { model.configuration.backendBaseURL },
                                    set: { value in
                                        model.updateConfiguration { configuration in
                                            configuration.backendBaseURL = value
                                        }
                                    }
                                ),
                                keyboardType: .URL,
                                isSecure: false
                            )

                            LabeledInput(
                                title: "Setup key",
                                text: Binding(
                                    get: { model.configuration.setupKey },
                                    set: { value in
                                        model.updateConfiguration { configuration in
                                            configuration.setupKey = value
                                        }
                                    }
                                ),
                                keyboardType: .default,
                                isSecure: true
                            )

                            LabeledInput(
                                title: "Device name",
                                text: Binding(
                                    get: { model.configuration.deviceName },
                                    set: { value in
                                        model.updateConfiguration { configuration in
                                            configuration.deviceName = value
                                        }
                                    }
                                ),
                                keyboardType: .default,
                                isSecure: false
                            )

                            Toggle(
                                isOn: Binding(
                                    get: { model.configuration.sampleDataEnabled },
                                    set: { enabled in
                                        model.updateConfiguration { configuration in
                                            configuration.sampleDataEnabled = enabled
                                        }
                                    }
                                )
                            ) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("Sample Data")
                                        .font(.headline)
                                        .foregroundStyle(IntentTheme.textPrimary)
                                    Text("Preview charts without connecting to Convex.")
                                        .font(.caption)
                                        .foregroundStyle(IntentTheme.textSecondary)
                                }
                            }
                            .tint(IntentTheme.accent)

                            Button {
                                Task {
                                    await model.pair()
                                }
                            } label: {
                                HStack {
                                    if model.isPairing {
                                        ProgressView()
                                            .tint(.white)
                                    } else {
                                        Image(systemName: "link")
                                    }
                                    Text(model.isPaired ? "Pair again" : "Pair")
                                }
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(IntentTheme.accent)
                            .disabled(model.isPairing || model.configuration.sampleDataEnabled)
                        }
                    }

                    IntentPanel {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Data Window")
                                .font(.headline)
                                .foregroundStyle(IntentTheme.textPrimary)

                            WindowPicker(model: model)
                        }
                    }

                    StatusMessages(model: model)
                }
                .padding(.horizontal, 18)
                .padding(.top, 14)
                .padding(.bottom, 28)
            }
        }
    }
}

private struct IntentScreenBackground<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        ZStack {
            IntentTheme.background
                .ignoresSafeArea()

            StarfieldView(starCount: 38, showShootingStars: false)
                .opacity(0.36)
                .ignoresSafeArea()

            content()
        }
    }
}

private struct HeaderView: View {
    @ObservedObject var model: IntentionalityAppModel

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Intent")
                    .font(.system(size: 42, weight: .black, design: .rounded))
                    .foregroundStyle(IntentTheme.textPrimary)

                Text(Date(), format: .dateTime.weekday(.wide).month(.abbreviated).day())
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(IntentTheme.textSecondary)
            }

            Spacer(minLength: 10)

            StatusPill(text: model.connectionStatus)
        }
    }
}

private struct StatusPill: View {
    let text: String

    var color: Color {
        text == "Connected" || text == "Sample data" ? IntentTheme.mint : IntentTheme.amber
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(text)
                .font(.caption.weight(.semibold))
                .foregroundStyle(IntentTheme.textPrimary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(IntentTheme.panelStrong, in: Capsule())
    }
}

private struct ManualEntrySheet: View {
    @ObservedObject var model: IntentionalityAppModel
    @Environment(\.dismiss) private var dismiss

    private var canRecord: Bool {
        (model.isPaired || model.configuration.sampleDataEnabled) && !model.isRecording
    }

    var body: some View {
        ZStack {
            IntentTheme.background
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Manual Entry")
                            .font(.system(size: 28, weight: .black, design: .rounded))
                            .foregroundStyle(IntentTheme.textPrimary)
                        Text("Record intentionality for this hour.")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(IntentTheme.textSecondary)
                    }

                    Spacer()

                    Text(scoreText(model.pendingScore))
                        .font(.system(size: 44, weight: .black, design: .rounded))
                        .foregroundStyle(IntentTheme.accent)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }

                Slider(value: $model.pendingScore, in: 0...10, step: 1)
                    .tint(IntentTheme.accent)

                Button {
                    Task {
                        await model.recordCurrentHour()
                        if model.lastError == nil {
                            dismiss()
                        }
                    }
                } label: {
                    HStack {
                        if model.isRecording {
                            ProgressView()
                                .tint(.white)
                        } else {
                            Image(systemName: "checkmark.circle.fill")
                        }
                        Text("Record")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(IntentTheme.accent)
                .disabled(!canRecord)

                if !model.isPaired && !model.configuration.sampleDataEnabled {
                    NoticeRow(
                        text: "Enable Sample Data or pair the app before recording.",
                        color: IntentTheme.amber,
                        systemImage: "exclamationmark.triangle.fill"
                    )
                }
            }
            .padding(20)
        }
    }
}

private struct TodaySnapshotGrid: View {
    let snapshot: IntentionalitySnapshot

    private var todayEntries: [IntentionalityEntry] {
        snapshot.recentEntries.filter { Calendar.current.isDateInToday($0.date) }
    }

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
            MetricTile(
                title: "Today",
                value: optionalScoreText(snapshot.todayAverage),
                caption: deltaCaption(snapshot.deltaFromYesterday),
                systemImage: "sun.max.fill",
                tint: IntentTheme.amber
            )

            MetricTile(
                title: "Current Hour",
                value: optionalScoreText(snapshot.currentHourScore),
                caption: "latest hourly entry",
                systemImage: "clock.fill",
                tint: IntentTheme.accent
            )

            MetricTile(
                title: "Captured Today",
                value: "\(todayEntries.count)",
                caption: todayEntries.isEmpty ? "no hourly entries yet" : "hourly entries",
                systemImage: "calendar.badge.checkmark",
                tint: IntentTheme.mint
            )

            MetricTile(
                title: "Yesterday",
                value: optionalScoreText(snapshot.yesterdayAverage),
                caption: deltaCaption(snapshot.deltaFromYesterday),
                systemImage: "arrow.left.arrow.right",
                tint: IntentTheme.coral
            )
        }
    }
}

private struct ScoreSummaryHero: View {
    let snapshot: IntentionalitySnapshot

    private var score: Double {
        snapshot.todayAverage ?? snapshot.last24Average ?? snapshot.averageScore
    }

    private var band: ScoreBand {
        ScoreBand(score: score)
    }

    private var completionText: String {
        let capturedToday = snapshot.recentEntries.filter { Calendar.current.isDateInToday($0.date) }.count
        if capturedToday == 0 {
            return "No hours captured today"
        }
        if capturedToday == 1 {
            return "1 hour captured today"
        }
        return "\(capturedToday) hours captured today"
    }

    var body: some View {
        IntentPanel(padding: 18) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Intentionality Score")
                            .font(.headline)
                            .foregroundStyle(IntentTheme.textPrimary)
                        Text(completionText)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(IntentTheme.textSecondary)
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 2) {
                        Text(scoreText(score))
                            .font(.system(size: 42, weight: .black, design: .rounded))
                            .foregroundStyle(band.color)
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                        Text(band.title)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(band.color)
                    }
                }

                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.white.opacity(0.12))
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [IntentTheme.coral, IntentTheme.amber, IntentTheme.accent, IntentTheme.mint],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: max(8, proxy.size.width * min(max(score / 10, 0), 1)))
                    }
                }
                .frame(height: 10)

                HStack {
                    Text(deltaCaption(snapshot.deltaFromYesterday))
                    Spacer()
                    Text(snapshot.bestHourOfDay.map { "Best hour \($0.hour)" } ?? "Best hour unavailable")
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(IntentTheme.textSecondary)
            }
        }
    }
}

private struct TodaySignalComparisonChart: View {
    let snapshot: IntentionalitySnapshot
    @State private var selectedOffset: Int?

    private var comparison: SignalComparison {
        SignalComparison(entries: snapshot.recentEntries)
    }

    private var selectedPoint: SignalComparisonPoint? {
        guard let selectedOffset else {
            return comparison.points.last(where: { $0.currentScore != nil }) ?? comparison.points.last
        }
        return comparison.points.min { lhs, rhs in
            abs(lhs.offset - selectedOffset) < abs(rhs.offset - selectedOffset)
        }
    }

    var body: some View {
        ChartCard(title: "Today Signal", subtitle: "last 48 hours vs previous 48 hours") {
            if comparison.points.allSatisfy({ $0.currentScore == nil && $0.previousScore == nil }) {
                EmptyChartState()
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ChartLegend(items: [
                        .init(title: "Now", color: IntentTheme.accent),
                        .init(title: "Previous", color: IntentTheme.amber.opacity(0.78))
                    ])

                    if let selectedPoint {
                        SignalComparisonSummary(point: selectedPoint)
                    }

                    Chart {
                        ForEach(comparison.points) { point in
                            if let score = point.previousScore {
                                LineMark(
                                    x: .value("Hour offset", point.offset),
                                    y: .value("Previous score", score)
                                )
                                .interpolationMethod(.catmullRom)
                                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round, dash: [5, 5]))
                                .foregroundStyle(IntentTheme.amber.opacity(0.78))

                                PointMark(
                                    x: .value("Hour offset", point.offset),
                                    y: .value("Previous score", score)
                                )
                                .symbolSize(18)
                                .foregroundStyle(IntentTheme.amber.opacity(0.72))
                            }

                            if let score = point.currentScore {
                                AreaMark(
                                    x: .value("Hour offset", point.offset),
                                    y: .value("Current score", score)
                                )
                                .interpolationMethod(.catmullRom)
                                .foregroundStyle(
                                    LinearGradient(
                                        colors: [IntentTheme.accent.opacity(0.28), IntentTheme.accent.opacity(0.03)],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )

                                LineMark(
                                    x: .value("Hour offset", point.offset),
                                    y: .value("Current score", score)
                                )
                                .interpolationMethod(.catmullRom)
                                .lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                                .foregroundStyle(IntentTheme.accent)

                                PointMark(
                                    x: .value("Hour offset", point.offset),
                                    y: .value("Current score", score)
                                )
                                .symbolSize(32)
                                .foregroundStyle(IntentTheme.textPrimary)
                            }
                        }

                        if let selectedPoint {
                            RuleMark(x: .value("Selected hour", selectedPoint.offset))
                                .foregroundStyle(Color.white.opacity(0.28))
                                .lineStyle(StrokeStyle(lineWidth: 2, dash: [4, 4]))
                        }
                    }
                    .chartYScale(domain: 0...10)
                    .chartXScale(domain: 0...47)
                    .chartXSelection(value: $selectedOffset)
                    .chartYAxis {
                        AxisMarks(values: [0, 2, 4, 6, 8, 10]) {
                            AxisGridLine()
                            AxisValueLabel()
                                .foregroundStyle(IntentTheme.textSecondary)
                        }
                    }
                    .chartXAxis {
                        AxisMarks(values: [0, 12, 24, 36, 47]) { value in
                            AxisGridLine()
                            if let offset = value.as(Int.self) {
                                AxisValueLabel {
                                    Text(comparison.axisLabel(for: offset))
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(IntentTheme.textSecondary)
                                }
                            }
                        }
                    }
                    .frame(height: 220)
                }
            }
        }
    }
}

private struct SignalComparisonSummary: View {
    let point: SignalComparisonPoint

    private var currentText: String {
        point.currentScore.map(scoreText) ?? "--"
    }

    private var previousText: String {
        point.previousScore.map(scoreText) ?? "--"
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(currentText)
                    .font(.system(size: 22, weight: .black, design: .rounded))
                    .foregroundStyle(point.currentScore.map(scoreColor) ?? IntentTheme.textSecondary)
                    .monospacedDigit()
                Text(point.currentDate.formatted(date: .omitted, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(IntentTheme.textSecondary)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(previousText)
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(IntentTheme.amber)
                    .monospacedDigit()
                Text("previous 48h")
                    .font(.caption2)
                    .foregroundStyle(IntentTheme.textSecondary)
            }

            Spacer(minLength: 0)

            if let current = point.currentScore, let previous = point.previousScore {
                let delta = current - previous
                Text(delta == 0 ? "flat" : "\(delta > 0 ? "+" : "")\(String(format: "%.1f", delta))")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(delta >= 0 ? IntentTheme.mint : IntentTheme.coral)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background((delta >= 0 ? IntentTheme.mint : IntentTheme.coral).opacity(0.14), in: Capsule())
            }
        }
        .padding(10)
        .background(IntentTheme.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(IntentTheme.accent.opacity(0.20), lineWidth: 1)
        )
    }
}

private struct SignalComparison {
    let points: [SignalComparisonPoint]
    private let calendar = Calendar.current

    init(entries: [IntentionalityEntry]) {
        let sortedEntries = entries.sorted { $0.hourStartMs < $1.hourStartMs }
        let latestDate = sortedEntries.last?.date ?? Date()
        let latestHour = Calendar.current.dateInterval(of: .hour, for: latestDate)?.start ?? latestDate
        let currentStart = Calendar.current.date(byAdding: .hour, value: -47, to: latestHour) ?? latestHour
        let previousStart = Calendar.current.date(byAdding: .hour, value: -48, to: currentStart) ?? currentStart
        let entriesByHour = Dictionary(uniqueKeysWithValues: sortedEntries.map { ($0.hourStartMs, $0) })

        points = (0..<48).map { offset in
            let currentDate = Calendar.current.date(byAdding: .hour, value: offset, to: currentStart) ?? currentStart
            let previousDate = Calendar.current.date(byAdding: .hour, value: offset, to: previousStart) ?? previousStart
            let currentKey = Int(currentDate.timeIntervalSince1970 * 1000)
            let previousKey = Int(previousDate.timeIntervalSince1970 * 1000)

            return SignalComparisonPoint(
                offset: offset,
                currentDate: currentDate,
                previousDate: previousDate,
                currentScore: entriesByHour[currentKey]?.score,
                previousScore: entriesByHour[previousKey]?.score
            )
        }
    }

    func axisLabel(for offset: Int) -> String {
        if offset == 47 {
            return "now"
        }
        return "-\(47 - offset)h"
    }
}

private struct SignalComparisonPoint: Identifiable {
    var id: Int { offset }
    let offset: Int
    let currentDate: Date
    let previousDate: Date
    let currentScore: Double?
    let previousScore: Double?
}

private struct DailyAverageChart: View {
    let snapshot: IntentionalitySnapshot
    @State private var selectedDay: Date?

    private var selectedAverage: IntentionalityDailyAverage? {
        guard let selectedDay else { return snapshot.dailyAverages.last }
        return snapshot.dailyAverages.min { lhs, rhs in
            abs(lhs.date.timeIntervalSince(selectedDay)) < abs(rhs.date.timeIntervalSince(selectedDay))
        }
    }

    var body: some View {
        ChartCard(title: "Daily Average", subtitle: "\(snapshot.windowDays)-day window") {
            if snapshot.dailyAverages.isEmpty {
                EmptyChartState()
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ChartLegend(items: [
                        .init(title: "Daily average", color: IntentTheme.mint),
                        .init(title: "Window average", color: IntentTheme.amber)
                    ])

                    if let selectedAverage {
                        SelectedScoreSummary(
                            title: selectedAverage.date.formatted(date: .abbreviated, time: .omitted),
                            value: scoreText(selectedAverage.average),
                            subtitle: "\(selectedAverage.count) captured \(selectedAverage.count == 1 ? "hour" : "hours")",
                            color: scoreColor(selectedAverage.average)
                        )
                    }

                Chart {
                    ForEach(snapshot.dailyAverages) { day in
                        BarMark(
                            x: .value("Day", day.date, unit: .day),
                            y: .value("Average", day.average)
                        )
                        .foregroundStyle(IntentTheme.mint)
                    }

                    RuleMark(y: .value("Window average", snapshot.averageScore))
                        .foregroundStyle(IntentTheme.amber)
                        .lineStyle(StrokeStyle(lineWidth: 2, dash: [4, 4]))
                        .annotation(position: .top, alignment: .trailing) {
                            Text("avg \(scoreText(snapshot.averageScore))")
                                .font(.caption2.bold())
                                .foregroundStyle(IntentTheme.amber)
                        }

                    if let selectedAverage {
                        RuleMark(x: .value("Selected day", selectedAverage.date, unit: .day))
                            .foregroundStyle(Color.white.opacity(0.28))
                            .lineStyle(StrokeStyle(lineWidth: 2, dash: [4, 4]))
                    }
                }
                .chartYScale(domain: 0...10)
                .chartXSelection(value: $selectedDay)
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 5)) {
                        AxisGridLine()
                        AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                            .foregroundStyle(IntentTheme.textSecondary)
                    }
                }
                .chartYAxis {
                    AxisMarks(values: [0, 2, 4, 6, 8, 10]) {
                        AxisGridLine()
                        AxisValueLabel()
                            .foregroundStyle(IntentTheme.textSecondary)
                    }
                }
                .frame(height: 240)
                }
            }
        }
    }
}

private struct HourOfDayChart: View {
    let snapshot: IntentionalitySnapshot
    @State private var selectedHour: Int?

    private var plottedHours: [IntentionalityHourlyAverage] {
        snapshot.hourlyAverages.filter { $0.average != nil }
    }

    private var selectedAverage: IntentionalityHourlyAverage? {
        guard let selectedHour else {
            return snapshot.bestHourOfDay.map {
                IntentionalityHourlyAverage(id: $0.id, hour: $0.hour, label: $0.label, average: $0.average, count: $0.count)
            } ?? plottedHours.first
        }
        return plottedHours.first { $0.hour == selectedHour }
    }

    var body: some View {
        ChartCard(title: "Hour of Day", subtitle: "average score by local hour") {
            if plottedHours.isEmpty {
                EmptyChartState()
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ChartLegend(items: [
                        .init(title: "Daytime", color: IntentTheme.accent),
                        .init(title: "Off-hours", color: IntentTheme.amber)
                    ])

                    if let selectedAverage, let average = selectedAverage.average {
                        SelectedScoreSummary(
                            title: "\(selectedAverage.hour)",
                            value: scoreText(average),
                            subtitle: "\(selectedAverage.count) captured \(selectedAverage.count == 1 ? "hour" : "hours")",
                            color: scoreColor(average)
                        )
                    }

                Chart {
                ForEach(plottedHours) { hour in
                    if let average = hour.average {
                        BarMark(
                            x: .value("Hour", hour.hour),
                            y: .value("Average", average)
                        )
                        .foregroundStyle(hour.hour >= 8 && hour.hour <= 18 ? IntentTheme.accent : IntentTheme.amber)
                    }
                }

                    if let selectedAverage {
                        RuleMark(x: .value("Selected hour", selectedAverage.hour))
                            .foregroundStyle(Color.white.opacity(0.28))
                            .lineStyle(StrokeStyle(lineWidth: 2, dash: [4, 4]))
                    }
            }
            .chartYScale(domain: 0...10)
                .chartXSelection(value: $selectedHour)
            .chartXAxis {
                AxisMarks(values: [0, 4, 8, 12, 16, 20, 23]) { value in
                    AxisGridLine()
                    if let hour = value.as(Int.self) {
                        AxisValueLabel {
                            Text("\(hour)")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(IntentTheme.textSecondary)
                        }
                    }
                }
            }
                .chartYAxis {
                    AxisMarks(values: [0, 2, 4, 6, 8, 10]) {
                        AxisGridLine()
                        AxisValueLabel()
                            .foregroundStyle(IntentTheme.textSecondary)
                    }
                }
            .frame(height: 250)
                }
            }
        }
    }
}

private struct TodayHourStrip: View {
    let snapshot: IntentionalitySnapshot

    private var todayEntries: [IntentionalityEntry] {
        return snapshot.recentEntries
            .filter { Calendar.current.isDateInToday($0.date) }
            .sorted { $0.hourStartMs < $1.hourStartMs }
    }

    var body: some View {
        IntentPanel {
            VStack(alignment: .leading, spacing: 12) {
                Text("Captured Hours")
                    .font(.headline)
                    .foregroundStyle(IntentTheme.textPrimary)

                if todayEntries.isEmpty {
                    Text("No hourly entries yet.")
                        .font(.subheadline)
                        .foregroundStyle(IntentTheme.textSecondary)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(todayEntries) { entry in
                                VStack(spacing: 5) {
                                    Text("\(entry.hour)")
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(IntentTheme.textSecondary)
                                        .lineLimit(1)

                                    Text(scoreText(entry.score))
                                        .font(.system(size: 18, weight: .black, design: .rounded))
                                        .foregroundStyle(IntentTheme.textPrimary)
                                        .monospacedDigit()
                                }
                                .frame(width: 62, height: 58)
                                .background(scoreColor(entry.score).opacity(0.22), in: RoundedRectangle(cornerRadius: 8))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(scoreColor(entry.score).opacity(0.55), lineWidth: 1)
                                )
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct RecentEntriesList: View {
    let snapshot: IntentionalitySnapshot

    var body: some View {
        IntentPanel {
            VStack(alignment: .leading, spacing: 12) {
                Text("Latest")
                    .font(.headline)
                    .foregroundStyle(IntentTheme.textPrimary)

                ForEach(snapshot.recentEntries.prefix(8)) { entry in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(entry.date, format: .dateTime.weekday(.abbreviated).hour().minute())
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(IntentTheme.textPrimary)
                            Text(entry.source.replacingOccurrences(of: "_", with: " "))
                                .font(.caption)
                                .foregroundStyle(IntentTheme.textSecondary)
                        }

                        Spacer()

                        Text(scoreText(entry.score))
                            .font(.title3.bold())
                            .foregroundStyle(scoreColor(entry.score))
                            .monospacedDigit()
                    }
                    .padding(.vertical, 4)

                    if entry.id != snapshot.recentEntries.prefix(8).last?.id {
                        Divider()
                            .overlay(IntentTheme.border)
                    }
                }
            }
        }
    }
}

private struct PairingPrompt: View {
    var body: some View {
        IntentPanel {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "link.badge.plus")
                    .font(.title2)
                    .foregroundStyle(IntentTheme.amber)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Pair Intent")
                        .font(.headline)
                        .foregroundStyle(IntentTheme.textPrimary)
                    Text("Add the Convex URL and setup key in Settings.")
                        .font(.subheadline)
                        .foregroundStyle(IntentTheme.textSecondary)
                }
            }
        }
    }
}

private struct LoadingPanel: View {
    let isPaired: Bool

    var body: some View {
        IntentPanel {
            HStack(spacing: 12) {
                ProgressView()
                    .tint(IntentTheme.textPrimary)
                Text(isPaired ? "Loading metrics" : "Waiting for setup")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(IntentTheme.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct EmptyChartState: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.xyaxis.line")
                .font(.title2)
                .foregroundStyle(IntentTheme.textSecondary)
            Text("No data")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(IntentTheme.textSecondary)
        }
        .frame(maxWidth: .infinity, minHeight: 160)
    }
}

private struct IntentInsightItem: Identifiable {
    let id = UUID()
    let title: String
    let value: String
    let subtitle: String
    let tint: Color
}

private struct IntentInsightPillRow: View {
    let items: [IntentInsightItem]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(items) { item in
                    IntentInsightPill(item: item)
                }
            }
            .padding(.horizontal, 1)
        }
    }
}

private struct IntentInsightPill: View {
    let item: IntentInsightItem

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(item.title.uppercased())
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(IntentTheme.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            Text(item.value)
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundStyle(item.tint)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            Text(item.subtitle)
                .font(.caption2)
                .foregroundStyle(IntentTheme.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(width: 104, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(item.tint.opacity(0.28), lineWidth: 1)
        )
    }
}

private struct ChartLegendItem: Identifiable {
    let id = UUID()
    let title: String
    let color: Color
}

private struct ChartLegend: View {
    let items: [ChartLegendItem]

    var body: some View {
        HStack(spacing: 12) {
            ForEach(items) { item in
                HStack(spacing: 6) {
                    Circle()
                        .fill(item.color)
                        .frame(width: 8, height: 8)
                    Text(item.title)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(IntentTheme.textSecondary)
                        .lineLimit(1)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct SelectedScoreSummary: View {
    let title: String
    let value: String
    let subtitle: String
    let color: Color

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(value)
                .font(.system(size: 22, weight: .black, design: .rounded))
                .foregroundStyle(color)
                .monospacedDigit()

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(IntentTheme.textPrimary)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(IntentTheme.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(10)
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(color.opacity(0.24), lineWidth: 1)
        )
    }
}

private struct ScoreBand {
    let title: String
    let color: Color

    init(score: Double) {
        if score >= 8 {
            title = "High"
            color = IntentTheme.mint
        } else if score >= 6 {
            title = "Steady"
            color = IntentTheme.accent
        } else if score >= 4 {
            title = "Mixed"
            color = IntentTheme.amber
        } else {
            title = "Low"
            color = IntentTheme.coral
        }
    }
}

private struct WindowPicker: View {
    @ObservedObject var model: IntentionalityAppModel

    var body: some View {
        Picker(
            "Window",
            selection: Binding(
                get: { model.configuration.windowDays },
                set: { model.setWindowDays($0) }
            )
        ) {
            Text("7D").tag(7)
            Text("30D").tag(30)
            Text("90D").tag(90)
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 230)
    }
}

private struct StatusMessages: View {
    @ObservedObject var model: IntentionalityAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let notice = model.lastNotice {
                NoticeRow(text: notice, color: IntentTheme.mint, systemImage: "checkmark.circle.fill")
            }

            if let error = model.lastError {
                NoticeRow(text: error, color: IntentTheme.coral, systemImage: "exclamationmark.triangle.fill")
            }
        }
    }
}

private struct NoticeRow: View {
    let text: String
    let color: Color
    let systemImage: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(color)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(IntentTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct LabeledInput: View {
    let title: String
    @Binding var text: String
    let keyboardType: UIKeyboardType
    let isSecure: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(IntentTheme.textSecondary)

            Group {
                if isSecure {
                    SecureField(title, text: $text)
                } else {
                    TextField(title, text: $text)
                }
            }
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(keyboardType)
            .padding(12)
            .foregroundStyle(IntentTheme.textPrimary)
            .background(Color.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(IntentTheme.border, lineWidth: 1)
            )
        }
    }
}

private func homeInsightItems(snapshot: IntentionalitySnapshot) -> [IntentInsightItem] {
    [
        IntentInsightItem(
            title: "last 24h",
            value: optionalScoreText(snapshot.last24Average),
            subtitle: "rolling score",
            tint: scoreColor(snapshot.last24Average ?? snapshot.averageScore)
        ),
        IntentInsightItem(
            title: "capture",
            value: "\(Int(snapshot.responseRate7d.rounded()))%",
            subtitle: "past week",
            tint: IntentTheme.mint
        ),
        IntentInsightItem(
            title: "streak",
            value: "\(snapshot.currentStreakDays)d",
            subtitle: "daily rhythm",
            tint: IntentTheme.coral
        )
    ]
}

private func trendInsightItems(snapshot: IntentionalitySnapshot) -> [IntentInsightItem] {
    [
        IntentInsightItem(
            title: "window avg",
            value: scoreText(snapshot.averageScore),
            subtitle: "\(snapshot.windowDays) days",
            tint: scoreColor(snapshot.averageScore)
        ),
        IntentInsightItem(
            title: "best hour",
            value: snapshot.bestHourOfDay.map { "\($0.hour)" } ?? "--",
            subtitle: snapshot.bestHourOfDay.map { scoreText($0.average) } ?? "not enough data",
            tint: IntentTheme.accent
        ),
        IntentInsightItem(
            title: "samples",
            value: "\(snapshot.totalEntries)",
            subtitle: "captured hours",
            tint: IntentTheme.amber
        )
    ]
}

private func scoreText(_ value: Double) -> String {
    if value.rounded() == value {
        return "\(Int(value))/10"
    }

    return String(format: "%.1f/10", value)
}

private func optionalScoreText(_ value: Double?) -> String {
    guard let value else {
        return "--"
    }

    return scoreText(value)
}

private func deltaCaption(_ value: Double?) -> String {
    guard let value else {
        return "no prior-day comparison"
    }

    if value == 0 {
        return "flat vs yesterday"
    }

    let prefix = value > 0 ? "+" : ""
    return "\(prefix)\(String(format: "%.1f", value)) vs yesterday"
}

private func scoreColor(_ value: Double) -> Color {
    if value >= 8 {
        return IntentTheme.mint
    }
    if value >= 6 {
        return IntentTheme.accent
    }
    if value >= 4 {
        return IntentTheme.amber
    }
    return IntentTheme.coral
}

#Preview {
    ContentView(model: IntentionalityAppModel())
}
