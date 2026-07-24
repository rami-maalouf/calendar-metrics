//
//  IntentVisualsView.swift
//  Intent
//
//  Big, minimal, per-signal visuals. One tile per metric, the chart is the point.
//

import Charts
import SwiftUI

struct IntentVisualsView: View {
    @ObservedObject var model: IntentAppModel
    @State private var heroMode: VisualsHeroMode = .deepWork

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header

                if let metrics = model.metricsState, hasAnyData(metrics) {
                    heroSection(metrics)

                    if metrics.reviewedSessions > 0 {
                        signalGrid(metrics)
                        distractionsTile(metrics)
                    }
                } else if model.screenDay == nil && model.screenDays.isEmpty {
                    emptyState
                }

                if let screenDay = model.screenDay {
                    ScreenTimeTile(day: screenDay, recentDays: model.screenDays)
                }
            }
            .padding(28)
        }
    }

    private func hasAnyData(_ metrics: IntentMetricsState) -> Bool {
        metrics.reviewedSessions > 0
            || !(metrics.dailyDurationSeries ?? []).isEmpty
            || !(model.intentionalityState?.dailyAverages ?? []).isEmpty
    }

    private func heroSection(_ metrics: IntentMetricsState) -> some View {
        let points = heroPoints(for: heroMode, in: metrics)
        let intentionality = model.intentionalityState

        return HeroTile(
            mode: $heroMode,
            headline: heroHeadline(for: heroMode, in: metrics, points: points),
            headlineSuffix: heroSuffix(for: heroMode),
            points: points,
            delta: heroMode == .intentionality ? intentionality?.deltaFromYesterday : nil,
            deltaCaption: "vs yesterday",
            streakDays: heroMode == .intentionality ? intentionality?.currentStreakDays : nil
        )
    }

    private func heroSuffix(for mode: VisualsHeroMode) -> String {
        switch mode {
        case .deepWork:
            return "/ day"
        case .score:
            return "/ 10"
        case .intentionality:
            return model.intentionalityState?.todayAverage != nil ? "/ 10 today" : "/ 10"
        }
    }

    private func heroPoints(for mode: VisualsHeroMode, in metrics: IntentMetricsState) -> [VisualsDayPoint] {
        switch mode {
        case .deepWork:
            return (metrics.dailyDurationSeries ?? []).map { day in
                VisualsDayPoint(
                    day: Date(timeIntervalSince1970: TimeInterval(day.dayStart) / 1000),
                    value: day.durationMs / 3_600_000
                )
            }
        case .score:
            return scoreDailyPoints(in: metrics)
        case .intentionality:
            // the intentionality fetch covers at least 35 days; clip to the selected window
            let windowStart = Calendar.current.startOfDay(for: Date())
                .addingTimeInterval(-TimeInterval(model.metricsWindowDays) * 24 * 60 * 60)
            return (model.intentionalityState?.dailyAverages ?? [])
                .compactMap { day -> VisualsDayPoint? in
                    guard let average = day.average else {
                        return nil
                    }
                    return VisualsDayPoint(
                        day: Date(timeIntervalSince1970: day.dayStartMs / 1000),
                        value: average
                    )
                }
                .filter { $0.day >= windowStart }
                .sorted { $0.day < $1.day }
        }
    }

    // one score per day: the mean of every numeric signal except distractions
    private func scoreDailyPoints(in metrics: IntentMetricsState) -> [VisualsDayPoint] {
        if let series = metrics.signalDailySeries, !series.isEmpty {
            return series.compactMap { day in
                let values = day.metrics
                    .filter { $0.key != "distractions" }
                    .map(\.value)
                guard !values.isEmpty else {
                    return nil
                }
                return VisualsDayPoint(
                    day: Date(timeIntervalSince1970: TimeInterval(day.dayStart) / 1000),
                    value: values.reduce(0, +) / Double(values.count)
                )
            }
        }

        var buckets: [Date: [Double]] = [:]
        for point in metrics.trendSeries {
            let values = point.metrics
                .filter { $0.key != "distractions" }
                .map(\.value)
            guard !values.isEmpty else {
                continue
            }
            let day = Calendar.current.startOfDay(
                for: Date(timeIntervalSince1970: TimeInterval(point.observedAt) / 1000)
            )
            buckets[day, default: []].append(values.reduce(0, +) / Double(values.count))
        }

        return buckets.keys.sorted().map { day in
            let values = buckets[day] ?? []
            return VisualsDayPoint(
                day: day,
                value: values.reduce(0, +) / Double(max(values.count, 1))
            )
        }
    }

    private func heroHeadline(
        for mode: VisualsHeroMode,
        in metrics: IntentMetricsState,
        points: [VisualsDayPoint]
    ) -> String {
        switch mode {
        case .deepWork:
            guard !points.isEmpty else {
                return "0m"
            }
            let averageHours = points.map(\.value).reduce(0, +) / Double(points.count)
            return hoursLabel(averageHours)
        case .score:
            let averages = metrics.signalAverages.map(\.average)
            guard !averages.isEmpty else {
                return "—"
            }
            return String(format: "%.1f", averages.reduce(0, +) / Double(averages.count))
        case .intentionality:
            let state = model.intentionalityState
            guard let value = state?.todayAverage ?? state?.averageScore ?? points.last?.value else {
                return "—"
            }
            return String(format: "%.1f", value)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            Text("Visuals")
                .font(.system(size: 40, weight: .black, design: .rounded))

            Spacer(minLength: 12)

            VisualsWindowPicker(
                selection: model.metricsWindowDays,
                onSelect: { model.setMetricsWindowDays($0) }
            )

            Button {
                Task {
                    await model.refreshMetricsNow()
                }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 13, weight: .bold))
                    .padding(8)
                    .background(Circle().fill(Color.primary.opacity(0.06)))
            }
            .buttonStyle(.plain)
            .disabled(!model.configuration.isPaired)
        }
    }

    private func signalGrid(_ metrics: IntentMetricsState) -> some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 360), spacing: 16)],
            spacing: 16
        ) {
            ForEach(metrics.signalAverages) { signal in
                SignalTile(
                    title: signal.title,
                    average: signal.average,
                    delta: signal.deltaFromPrevious,
                    hue: VisualsPalette.hue(for: signal.key),
                    points: dailyPoints(for: signal.key, in: metrics)
                )
            }
        }
    }

    private func distractionsTile(_ metrics: IntentMetricsState) -> some View {
        let points = dailyPoints(for: "distractions", in: metrics)
        let dailyAverage = points.isEmpty
            ? 0
            : points.map(\.value).reduce(0, +) / Double(points.count)

        return DistractionsTile(
            title: "Distractions",
            dailyAverage: dailyAverage,
            hue: VisualsPalette.hue(for: "distractions"),
            points: points
        )
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "waveform.path.ecg")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(.tertiary)

            Text("Review a few blocks and your signals will show up here.")
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 120)
    }

    // one point per local day; the backend series covers the full window,
    // the trend-series fallback only covers the last 12 reviewed sessions
    private func dailyPoints(for key: String, in metrics: IntentMetricsState) -> [VisualsDayPoint] {
        if let series = metrics.signalDailySeries, !series.isEmpty {
            return series.compactMap { day in
                guard let value = day.metrics[key] else {
                    return nil
                }
                return VisualsDayPoint(
                    day: Date(timeIntervalSince1970: TimeInterval(day.dayStart) / 1000),
                    value: value
                )
            }
        }

        var buckets: [Date: [Double]] = [:]
        for point in metrics.trendSeries {
            guard let value = point.metrics[key] else {
                continue
            }
            let day = Calendar.current.startOfDay(
                for: Date(timeIntervalSince1970: TimeInterval(point.observedAt) / 1000)
            )
            buckets[day, default: []].append(value)
        }

        let isCount = key == "distractions"
        return buckets.keys.sorted().map { day in
            let values = buckets[day] ?? []
            let value = isCount
                ? values.reduce(0, +)
                : values.reduce(0, +) / Double(max(values.count, 1))
            return VisualsDayPoint(day: day, value: value)
        }
    }
}

struct VisualsDayPoint: Identifiable, Equatable {
    let day: Date
    let value: Double

    var id: Date { day }
}

enum VisualsHeroMode: String, CaseIterable, Identifiable {
    case deepWork = "Deep Work"
    case score = "Score"
    case intentionality = "Intentionality"

    var id: String { rawValue }
}

func hoursLabel(_ hours: Double) -> String {
    let totalMinutes = Int((hours * 60).rounded())
    if totalMinutes < 60 {
        return "\(totalMinutes)m"
    }
    let wholeHours = totalMinutes / 60
    let minutes = totalMinutes % 60
    return minutes == 0 ? "\(wholeHours)h" : "\(wholeHours)h \(minutes)m"
}

// trailing 7-day moving average, one smoothed value per day with data
func weeklyMovingAverage(of points: [VisualsDayPoint]) -> [VisualsDayPoint] {
    let window: TimeInterval = 6 * 24 * 60 * 60
    return points.map { point in
        let values = points
            .filter { $0.day > point.day.addingTimeInterval(-window - 1) && $0.day <= point.day }
            .map(\.value)
        return VisualsDayPoint(
            day: point.day,
            value: values.reduce(0, +) / Double(max(values.count, 1))
        )
    }
}

private struct HeroTile: View {
    @Binding var mode: VisualsHeroMode
    let headline: String
    let headlineSuffix: String
    let points: [VisualsDayPoint]
    var delta: Double?
    var deltaCaption: String?
    var streakDays: Int?

    var body: some View {
        VisualsPanel {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center) {
                    Picker("", selection: $mode) {
                        ForEach(VisualsHeroMode.allCases) { option in
                            Text(option.rawValue).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 330)

                    Spacer()

                    HStack(spacing: 14) {
                        if mode == .intentionality {
                            HStack(spacing: 5) {
                                Capsule()
                                    .fill(Color.accentColor)
                                    .frame(width: 14, height: 2)
                                Text("Daily average")
                            }
                        } else {
                            HStack(spacing: 5) {
                                Circle()
                                    .fill(Color.accentColor.opacity(0.45))
                                    .frame(width: 7, height: 7)
                                Text("Daily")
                            }
                            HStack(spacing: 5) {
                                Capsule()
                                    .fill(Color.accentColor)
                                    .frame(width: 14, height: 2)
                                Text("7-day avg")
                            }
                        }
                    }
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                }

                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(headline)
                        .font(.system(size: 52, weight: .heavy, design: .rounded))

                    Text(headlineSuffix)
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundStyle(.tertiary)

                    Spacer()

                    HStack(spacing: 8) {
                        if let delta, abs(delta) >= 0.05 {
                            HStack(spacing: 5) {
                                DeltaBadge(delta: delta, upIsGood: true)
                                if let deltaCaption {
                                    Text(deltaCaption)
                                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }

                        if let streakDays, streakDays > 0 {
                            HStack(spacing: 4) {
                                Image(systemName: "flame.fill")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(.orange)
                                Text("\(streakDays)-day streak")
                                    .font(.system(size: 12, weight: .bold, design: .rounded))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(Color.primary.opacity(0.06))
                            )
                        }
                    }
                }

                HeroChart(mode: mode, points: points)
                    .frame(height: 230)
            }
        }
    }
}

private struct HeroChart: View {
    let mode: VisualsHeroMode
    let points: [VisualsDayPoint]

    @State private var hovered: VisualsDayPoint?

    private var movingAverage: [VisualsDayPoint] {
        weeklyMovingAverage(of: points)
    }

    private var yDomain: ClosedRange<Double> {
        switch mode {
        case .deepWork:
            return 0...max(2, (points.map(\.value).max() ?? 0) * 1.2)
        case .score:
            return 0...10
        case .intentionality:
            return Self.zoomedDomain(for: points.map(\.value))
        }
    }

    // zoom the axis to the data so small day-to-day moves stay visible:
    // pad by 15% of the spread (min 0.5), keep at least a 3-point span, clamp to 0...10
    static func zoomedDomain(for values: [Double]) -> ClosedRange<Double> {
        guard let minValue = values.min(), let maxValue = values.max() else {
            return 0...10
        }

        let pad = max(0.5, (maxValue - minValue) * 0.15)
        var lower = max(0, minValue - pad)
        var upper = min(10, maxValue + pad)

        let minSpan = 3.0
        if upper - lower < minSpan {
            let center = (upper + lower) / 2
            lower = max(0, center - minSpan / 2)
            upper = min(10, lower + minSpan)
            lower = max(0, upper - minSpan)
        }

        return floor(lower)...ceil(upper)
    }

    private var scaleTicks: [Double] {
        switch mode {
        case .deepWork:
            return []
        case .score:
            return [0, 5, 10]
        case .intentionality:
            let domain = yDomain
            return [domain.lowerBound, (domain.lowerBound + domain.upperBound) / 2, domain.upperBound]
        }
    }

    private func valueLabel(_ value: Double) -> String {
        switch mode {
        case .deepWork:
            return hoursLabel(value)
        case .score, .intentionality:
            return String(format: "%.1f", value)
        }
    }

    var body: some View {
        Chart {
            // intentionality reads day to day: the line follows the daily averages
            // themselves; the other modes smooth with a 7-day moving average
            if mode == .intentionality {
                ForEach(points) { point in
                    AreaMark(
                        x: .value("Day", point.day),
                        y: .value("Value", point.value)
                    )
                    .interpolationMethod(.monotone)
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color.accentColor.opacity(0.14), Color.accentColor.opacity(0.02)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                    LineMark(
                        x: .value("Day", point.day),
                        y: .value("Value", point.value)
                    )
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    .foregroundStyle(Color.accentColor)
                }
            }

            ForEach(points) { point in
                PointMark(
                    x: .value("Day", point.day),
                    y: .value("Value", point.value)
                )
                .symbolSize(130)
                .foregroundStyle(VisualsPalette.surface)

                PointMark(
                    x: .value("Day", point.day),
                    y: .value("Value", point.value)
                )
                .symbolSize(hovered == point ? 90 : 60)
                .foregroundStyle(Color.accentColor.opacity(hovered == point ? 1 : 0.45))
            }

            if mode != .intentionality {
                ForEach(movingAverage) { point in
                    LineMark(
                        x: .value("Day", point.day),
                        y: .value("Average", point.value)
                    )
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    .foregroundStyle(Color.accentColor)
                }
            }

            if let hovered {
                RuleMark(x: .value("Day", hovered.day))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .foregroundStyle(Color.primary.opacity(0.15))
                    .annotation(
                        position: .top,
                        spacing: 6,
                        overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))
                    ) {
                        HoverReadout(
                            day: hovered.day,
                            text: valueLabel(hovered.value)
                        )
                    }
            }
        }
        .chartYScale(domain: yDomain)
        .chartXScale(domain: paddedDomain(for: points))
        .chartYAxis {
            if mode != .deepWork {
                AxisMarks(position: .trailing, values: scaleTicks) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 1))
                        .foregroundStyle(Color.primary.opacity(0.06))
                    AxisValueLabel {
                        if let number = value.as(Double.self) {
                            Text(
                                number == number.rounded()
                                    ? "\(Int(number))"
                                    : String(format: "%.1f", number)
                            )
                        }
                    }
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.tertiary)
                }
            } else {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 1))
                        .foregroundStyle(Color.primary.opacity(0.06))
                    AxisValueLabel {
                        if let number = value.as(Double.self) {
                            Text(hoursLabel(number))
                        }
                    }
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.tertiary)
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 6)) { _ in
                AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
        }
        .chartHover(points: points, hovered: $hovered)
    }
}

// fixed hue per metric so identity never shifts between visits or filters
enum VisualsPalette {
    static let surface = Color(light: "#fcfcfb", dark: "#1a1a19")
    static let deltaGood = Color(light: "#006300", dark: "#0ca30c")
    static let deltaBad = Color(light: "#d03b3b", dark: "#d03b3b")

    private static let hues: [String: Color] = [
        "focus": Color(light: "#2a78d6", dark: "#3987e5"),
        "discipline": Color(light: "#4a3aa7", dark: "#9085e9"),
        "mindfulness": Color(light: "#1baf7a", dark: "#199e70"),
        "energy": Color(light: "#eda100", dark: "#c98500"),
        "intentionality": Color(light: "#008300", dark: "#008300"),
        "purpose": Color(light: "#e87ba4", dark: "#d55181"),
        "distractions": Color(light: "#eb6834", dark: "#d95926"),
        "screenTime": Color(light: "#c98500", dark: "#f2b84b"),
    ]

    static func hue(for key: String) -> Color {
        hues[key] ?? Color(light: "#2a78d6", dark: "#3987e5")
    }
}

private struct SignalTile: View {
    let title: String
    let average: Double
    let delta: Double?
    let hue: Color
    let points: [VisualsDayPoint]

    var body: some View {
        VisualsPanel {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)

                    Spacer()

                    if let delta, abs(delta) >= 0.05 {
                        DeltaBadge(delta: delta, upIsGood: true)
                    }
                }

                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(String(format: "%.1f", average))
                        .font(.system(size: 46, weight: .heavy, design: .rounded))

                    Text("/ 10")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(.tertiary)
                }

                ScoreChart(points: points, hue: hue)
                    .frame(height: 150)
            }
        }
    }
}

private struct DistractionsTile: View {
    let title: String
    let dailyAverage: Double
    let hue: Color
    let points: [VisualsDayPoint]

    var body: some View {
        VisualsPanel {
            VStack(alignment: .leading, spacing: 14) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)

                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(String(format: "%.1f", dailyAverage))
                        .font(.system(size: 46, weight: .heavy, design: .rounded))

                    Text("/ day")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(.tertiary)
                }

                CountChart(points: points, hue: hue)
                    .frame(height: 160)
            }
        }
    }
}

private struct ScreenTimeTile: View {
    let day: IntentScreenDay
    let recentDays: [IntentScreenDay]

    private var hue: Color { VisualsPalette.hue(for: "screenTime") }

    private var hourlyPoints: [(hour: Int, hours: Double)] {
        day.hourlyTotals.enumerated().map { index, seconds in
            (hour: index, hours: seconds / 3600.0)
        }
    }

    private var trendPoints: [VisualsDayPoint] {
        recentDays.suffix(21).compactMap { row in
            guard let date = Self.dayKeyFormatter.date(from: row.dayKey) else {
                return nil
            }
            return VisualsDayPoint(day: date, value: row.totalSeconds / 3600.0)
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

    var body: some View {
        VisualsPanel {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("iPhone Screen")
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)
                        Text(day.dayKey)
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(.tertiary)
                    }

                    Spacer()

                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(hoursLabel(day.totalSeconds / 3600.0))
                            .font(.system(size: 46, weight: .heavy, design: .rounded))
                        Text("day")
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .foregroundStyle(.tertiary)
                    }
                }

                Chart {
                    ForEach(hourlyPoints, id: \.hour) { point in
                        BarMark(
                            x: .value("Hour", point.hour),
                            y: .value("Hours", point.hours)
                        )
                        .foregroundStyle(hue.gradient)
                        .cornerRadius(3)
                    }
                }
                .chartXScale(domain: 0...23)
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
                .frame(height: 170)

                if !day.topApps.isEmpty {
                    HStack(alignment: .top, spacing: 18) {
                        ForEach(Array(day.topApps.prefix(4).enumerated()), id: \.element.bundleId) { _, app in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(app.title)
                                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                Text(hoursLabel(app.seconds / 3600.0))
                                    .font(.system(size: 20, weight: .bold, design: .rounded))
                                    .monospacedDigit()
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }

                if trendPoints.count >= 2 {
                    CountChart(points: trendPoints, hue: hue)
                        .frame(height: 120)
                }
            }
        }
    }
}

private struct DeltaBadge: View {
    let delta: Double
    let upIsGood: Bool

    var body: some View {
        let improving = upIsGood ? delta > 0 : delta < 0

        HStack(spacing: 3) {
            Image(systemName: delta > 0 ? "arrow.up.right" : "arrow.down.right")
                .font(.system(size: 9, weight: .heavy))

            Text(String(format: "%+.1f", delta))
                .font(.system(size: 12, weight: .bold, design: .rounded))
        }
        .foregroundStyle(improving ? VisualsPalette.deltaGood : VisualsPalette.deltaBad)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule(style: .continuous)
                .fill((improving ? VisualsPalette.deltaGood : VisualsPalette.deltaBad).opacity(0.1))
        )
    }
}

private struct ScoreChart: View {
    let points: [VisualsDayPoint]
    let hue: Color

    @State private var hovered: VisualsDayPoint?

    var body: some View {
        Chart {
            ForEach(points) { point in
                AreaMark(
                    x: .value("Day", point.day),
                    y: .value("Score", point.value)
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(
                    LinearGradient(
                        colors: [hue.opacity(0.16), hue.opacity(0.02)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

                LineMark(
                    x: .value("Day", point.day),
                    y: .value("Score", point.value)
                )
                .interpolationMethod(.monotone)
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                .foregroundStyle(hue)
            }

            if let marked = hovered ?? points.last {
                PointMark(
                    x: .value("Day", marked.day),
                    y: .value("Score", marked.value)
                )
                .symbolSize(150)
                .foregroundStyle(VisualsPalette.surface)

                PointMark(
                    x: .value("Day", marked.day),
                    y: .value("Score", marked.value)
                )
                .symbolSize(70)
                .foregroundStyle(hue)
            }

            if let hovered {
                RuleMark(x: .value("Day", hovered.day))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .foregroundStyle(Color.primary.opacity(0.15))
                    .annotation(
                        position: .top,
                        spacing: 6,
                        overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))
                    ) {
                        HoverReadout(
                            day: hovered.day,
                            text: String(format: "%.1f", hovered.value)
                        )
                    }
            }
        }
        .chartYScale(domain: 0...10)
        .chartXScale(domain: paddedDomain(for: points))
        .chartYAxis {
            AxisMarks(position: .trailing, values: [0, 5, 10]) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 1))
                    .foregroundStyle(Color.primary.opacity(0.06))
                AxisValueLabel()
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
        }
        .chartHover(points: points, hovered: $hovered)
    }
}

private struct CountChart: View {
    let points: [VisualsDayPoint]
    let hue: Color

    @State private var hovered: VisualsDayPoint?

    private var yCeiling: Double {
        max(5, (points.map(\.value).max() ?? 0) * 1.15)
    }

    var body: some View {
        Chart {
            ForEach(points) { point in
                BarMark(
                    x: .value("Day", point.day, unit: .day),
                    y: .value("Count", point.value),
                    width: .fixed(14)
                )
                .cornerRadius(4)
                .foregroundStyle(hue.opacity(hovered == nil || hovered == point ? 1 : 0.35))
            }

            if let hovered {
                RuleMark(x: .value("Day", hovered.day))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .foregroundStyle(Color.primary.opacity(0.0))
                    .annotation(
                        position: .top,
                        spacing: 6,
                        overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))
                    ) {
                        HoverReadout(
                            day: hovered.day,
                            text: "\(Int(hovered.value.rounded()))"
                        )
                    }
            }
        }
        .chartYScale(domain: 0...yCeiling)
        .chartXScale(domain: paddedDomain(for: points))
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 1))
                    .foregroundStyle(Color.primary.opacity(0.06))
                AxisValueLabel()
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 6)) { _ in
                AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
        }
        .chartHover(points: points, hovered: $hovered)
    }
}

private struct HoverReadout: View {
    let day: Date
    let text: String

    var body: some View {
        HStack(spacing: 5) {
            Text(day.formatted(.dateTime.month(.abbreviated).day()))
                .foregroundStyle(.secondary)
            Text(text)
                .foregroundStyle(.primary)
        }
        .font(.system(size: 11, weight: .bold, design: .rounded))
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(
            Capsule(style: .continuous)
                .fill(.regularMaterial)
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                )
        )
    }
}

private struct VisualsPanel<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                )
        )
    }
}

private struct VisualsWindowPicker: View {
    let selection: Int
    let onSelect: (Int) -> Void

    private let options = [7, 21, 45]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(options, id: \.self) { option in
                Button {
                    onSelect(option)
                } label: {
                    Text("\(option)d")
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            Capsule(style: .continuous)
                                .fill(
                                    selection == option
                                        ? Color.accentColor.opacity(0.18)
                                        : Color.primary.opacity(0.06)
                                )
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// shared hover plumbing: snap the cursor to the nearest daily point
private struct ChartHoverModifier: ViewModifier {
    let points: [VisualsDayPoint]
    @Binding var hovered: VisualsDayPoint?

    func body(content: Content) -> some View {
        content.chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover(coordinateSpace: .local) { phase in
                        switch phase {
                        case .active(let location):
                            hovered = nearestPoint(to: location, proxy: proxy, geometry: geometry)
                        case .ended:
                            hovered = nil
                        }
                    }
            }
        }
    }

    private func nearestPoint(
        to location: CGPoint,
        proxy: ChartProxy,
        geometry: GeometryProxy
    ) -> VisualsDayPoint? {
        guard let anchor = proxy.plotFrame else {
            return nil
        }
        let plotFrame = geometry[anchor]
        guard let date: Date = proxy.value(atX: location.x - plotFrame.origin.x) else {
            return nil
        }
        return points.min {
            abs($0.day.timeIntervalSince(date)) < abs($1.day.timeIntervalSince(date))
        }
    }
}

private extension View {
    func chartHover(points: [VisualsDayPoint], hovered: Binding<VisualsDayPoint?>) -> some View {
        modifier(ChartHoverModifier(points: points, hovered: hovered))
    }
}

private func paddedDomain(for points: [VisualsDayPoint]) -> ClosedRange<Date> {
    let dayLength: TimeInterval = 24 * 60 * 60
    guard let first = points.first?.day, let last = points.last?.day else {
        let today = Calendar.current.startOfDay(for: Date())
        return today.addingTimeInterval(-7 * dayLength)...today
    }
    return first.addingTimeInterval(-dayLength)...last.addingTimeInterval(dayLength)
}

private extension Color {
    init(light: String, dark: String) {
        self.init(
            nsColor: NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                return NSColor(hexString: isDark ? dark : light)
            }
        )
    }
}

private extension NSColor {
    convenience init(hexString: String) {
        var value: UInt64 = 0
        Scanner(string: String(hexString.dropFirst())).scanHexInt64(&value)
        self.init(
            srgbRed: CGFloat((value >> 16) & 0xff) / 255,
            green: CGFloat((value >> 8) & 0xff) / 255,
            blue: CGFloat(value & 0xff) / 255,
            alpha: 1
        )
    }
}
