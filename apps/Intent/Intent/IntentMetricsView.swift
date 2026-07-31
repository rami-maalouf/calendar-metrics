//
//  IntentMetricsView.swift
//  Intent
//
//  Created by Codex on 2026-03-11.
//

import Charts
import SwiftUI

struct IntentMetricsView: View {
    @ObservedObject var model: IntentAppModel
    @State private var selectedSignalKey = "focus"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header

                if let metrics = model.metricsState, metrics.reviewedSessions > 0 {
                    snapshotHero(metrics)
                    overviewGrid(metrics)
                    cadenceStage(metrics)
                    trendStage(metrics)
                    bottomStage(metrics)
                    reflectionStage(metrics)
                } else {
                    emptyState
                }
            }
            .padding(28)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Visuals")
                    .font(.system(size: 40, weight: .black, design: .rounded))

                Text("A live read on how your recent blocks are actually going, not just whether a timer was running.")
                    .font(.system(size: 16, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 12) {
                MetricsWindowPicker(
                    selection: model.metricsWindowDays,
                    onSelect: { model.setMetricsWindowDays($0) }
                )

                Button("Refresh metrics") {
                    Task {
                        await model.refreshMetricsNow()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.configuration.isPaired)
            }
        }
    }

    private func snapshotHero(_ metrics: IntentMetricsState) -> some View {
        InsightPanel(padding: 0) {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.09, green: 0.17, blue: 0.30),
                                Color(red: 0.11, green: 0.29, blue: 0.36),
                                Color(red: 0.27, green: 0.16, blue: 0.08),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                Circle()
                    .fill(Color.white.opacity(0.14))
                    .frame(width: 240, height: 240)
                    .blur(radius: 50)
                    .offset(x: -40, y: -60)

                Circle()
                    .fill(Color.accentColor.opacity(0.24))
                    .frame(width: 220, height: 220)
                    .blur(radius: 70)
                    .offset(x: 520, y: -50)

                VStack(alignment: .leading, spacing: 20) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Recent signal")
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white.opacity(0.72))

                            Text(heroNarrative(for: metrics))
                                .font(.system(size: 30, weight: .black, design: .rounded))
                                .foregroundStyle(.white)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer(minLength: 16)

                        VStack(alignment: .trailing, spacing: 10) {
                            HighlightPill(title: "Window", value: "\(metrics.windowDays)d")
                            HighlightPill(title: "Updated", value: relativeText(from: metrics.generatedAt))
                        }
                    }

                    HStack(spacing: 14) {
                        SnapshotChip(
                            title: "Quality",
                            value: metrics.qualityScore == 0 ? "—" : formatScore(metrics.qualityScore),
                            accent: Color.white
                        )
                        SnapshotChip(
                            title: "Dominant lane",
                            value: (metrics.dominantCategory ?? "Mixed").capitalized,
                            accent: Color.accentColor
                        )
                        SnapshotChip(
                            title: "Distraction load",
                            value: metrics.averageDistractions == 0 ? "0.0" : formatScore(metrics.averageDistractions),
                            accent: Color.orange
                        )
                    }
                }
                .padding(26)
            }
            .frame(minHeight: 260)
        }
    }

    private func overviewGrid(_ metrics: IntentMetricsState) -> some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 190, maximum: 260), spacing: 16)],
            spacing: 16
        ) {
            InsightMetricCard(
                title: "Reviewed Blocks",
                value: "\(metrics.reviewedSessions)",
                caption: metrics.pendingReviews > 0
                    ? "\(metrics.pendingReviews) still open"
                    : "none open",
                tone: .accentColor,
                systemImage: "checkmark.seal.fill"
            )

            InsightMetricCard(
                title: "Review Closure",
                value: "\(Int(metrics.reviewCompletionRate.rounded()))%",
                caption: "\(metrics.completedSessions) completed sessions in window",
                tone: .accentColor,
                systemImage: "arrow.triangle.branch"
            )

            InsightMetricCard(
                title: "Average Block",
                value: durationText(Int(metrics.averageDurationMs)),
                caption: metrics.lastReviewedAt.map { "Last reviewed \(relativeText(from: $0))" } ?? "No recent review",
                tone: .orange,
                systemImage: "clock.fill"
            )

            InsightMetricCard(
                title: "Rhythm",
                value: "\(metrics.streakDays) day\(metrics.streakDays == 1 ? "" : "s")",
                caption: "Consecutive review days",
                tone: .purple,
                systemImage: "waveform.path.ecg"
            )
        }
    }

    private func trendStage(_ metrics: IntentMetricsState) -> some View {
        HStack(alignment: .top, spacing: 18) {
            InsightPanel {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Signal Trend")
                                .font(.system(size: 24, weight: .bold, design: .rounded))
                            Text("Recent blocks, plotted against the signal you care about right now.")
                                .foregroundStyle(.secondary)
                        }

                        Spacer()
                    }

                    signalSelector(metrics.signalAverages)

                    Chart {
                        ForEach(metrics.trendSeries) { point in
                            if let value = point.metrics[resolvedSignalKey(from: metrics)] {
                                AreaMark(
                                    x: .value("Session", chartDate(point.observedAt)),
                                    y: .value("Value", value)
                                )
                                .interpolationMethod(.catmullRom)
                                .foregroundStyle(
                                    LinearGradient(
                                        colors: [Color.accentColor.opacity(0.32), Color.accentColor.opacity(0.04)],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )

                                LineMark(
                                    x: .value("Session", chartDate(point.observedAt)),
                                    y: .value("Value", value)
                                )
                                .interpolationMethod(.catmullRom)
                                .lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                                .foregroundStyle(Color.accentColor)

                                PointMark(
                                    x: .value("Session", chartDate(point.observedAt)),
                                    y: .value("Value", value)
                                )
                                .symbolSize(42)
                                .foregroundStyle(Color.white)
                                .annotation(position: .top, spacing: 8) {
                                    if point.id == metrics.trendSeries.last?.id {
                                        Text("\(Int(value.rounded()))")
                                            .font(.caption2.bold())
                                            .padding(.horizontal, 7)
                                            .padding(.vertical, 4)
                                            .background(
                                                Capsule(style: .continuous)
                                                    .fill(Color.white)
                                            )
                                            .foregroundStyle(Color.black.opacity(0.8))
                                    }
                                }
                            }
                        }
                    }
                    .chartYScale(domain: 0 ... 10)
                    .chartXAxis {
                        AxisMarks(values: .automatic(desiredCount: 6)) { value in
                            AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                                .foregroundStyle(Color.primary.opacity(0.08))
                            AxisValueLabel {
                                if let date = value.as(Date.self) {
                                    Text(date, format: .dateTime.month(.abbreviated).day())
                                }
                            }
                        }
                    }
                    .chartYAxis {
                        AxisMarks(values: [0, 2, 4, 6, 8, 10]) { value in
                            AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                                .foregroundStyle(Color.primary.opacity(0.08))
                            AxisValueLabel()
                        }
                    }
                    .frame(height: 280)
                }
            }

            InsightPanel {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Signal Board")
                        .font(.system(size: 24, weight: .bold, design: .rounded))

                    Text("Averages across the recent review window, with directional change against the previous slice.")
                        .foregroundStyle(.secondary)

                    VStack(spacing: 14) {
                        ForEach(metrics.signalAverages.prefix(8)) { signal in
                            SignalBarRow(signal: signal)
                        }
                    }
                }
            }
            .frame(maxWidth: 360)
        }
    }

    private func cadenceStage(_ metrics: IntentMetricsState) -> some View {
        InsightPanel {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Cadence")
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                    Text("A quick read on whether the recent rhythm is consistent or spiky.")
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }

            if metrics.dailyVolume.isEmpty {
                Text("Daily review volume will appear here after a few reviewed days.")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 12)
            } else {
                HStack(alignment: .top, spacing: 18) {
                    Chart(metrics.dailyVolume) { point in
                        BarMark(
                            x: .value("Day", chartDate(point.dayStart)),
                            y: .value("Reviewed", point.reviewedCount)
                        )
                        .foregroundStyle(Color.accentColor.opacity(0.8))
                        .cornerRadius(8)

                        if let averageFocus = point.averageFocus {
                            LineMark(
                                x: .value("Day", chartDate(point.dayStart)),
                                y: .value("Focus", averageFocus)
                            )
                            .interpolationMethod(.catmullRom)
                            .lineStyle(StrokeStyle(lineWidth: 2.4, dash: [4, 3]))
                            .foregroundStyle(Color.orange)
                        }
                    }
                    .chartXAxis {
                        AxisMarks(values: .automatic(desiredCount: 8)) { value in
                            AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                                .foregroundStyle(Color.primary.opacity(0.08))
                            AxisValueLabel {
                                if let date = value.as(Date.self) {
                                    Text(date, format: .dateTime.month(.abbreviated).day())
                                }
                            }
                        }
                    }
                    .frame(height: 200)

                    VStack(alignment: .leading, spacing: 12) {
                        StatCallout(
                            title: "Best day",
                            value: bestCadenceDay(in: metrics),
                            caption: "Most reviewed blocks"
                        )
                        StatCallout(
                            title: "Focus runway",
                            value: focusRunwayLabel(in: metrics),
                            caption: "Average focus across recent review days"
                        )
                        StatCallout(
                            title: "Review density",
                            value: reviewDensityLabel(in: metrics),
                            caption: "Reviewed sessions per active day"
                        )
                    }
                    .frame(maxWidth: 260, alignment: .leading)
                }
            }
        }
    }

    private func bottomStage(_ metrics: IntentMetricsState) -> some View {
        HStack(alignment: .top, spacing: 18) {
            InsightPanel {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Category Balance")
                        .font(.system(size: 24, weight: .bold, design: .rounded))

                    Text("The work mix emerging from your own category labels.")
                        .foregroundStyle(.secondary)

                    if metrics.categoryBreakdown.isEmpty {
                        Text("Task categories will appear here after you review a few blocks.")
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 12)
                    } else {
                        Chart(metrics.categoryBreakdown) { item in
                            BarMark(
                                x: .value("Count", item.count),
                                y: .value("Category", item.label)
                            )
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [Color.orange, Color.pink.opacity(0.7)],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .cornerRadius(8)
                        }
                        .chartXAxis {
                            AxisMarks(position: .bottom)
                        }
                        .chartYAxis {
                            AxisMarks(position: .leading)
                        }
                        .frame(height: 240)

                        VStack(spacing: 10) {
                            ForEach(metrics.categoryBreakdown) { item in
                                HStack {
                                    Text(item.label.capitalized)
                                    Spacer()
                                    Text("\(item.count) · \(Int(item.share.rounded()))%")
                                        .foregroundStyle(.secondary)
                                }
                                .font(.caption.weight(.medium))
                            }
                        }
                    }
                }
            }

            InsightPanel {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Distraction Pressure")
                        .font(.system(size: 24, weight: .bold, design: .rounded))

                    Text("Not all drift is equal. This tracks how noisy each recent block felt.")
                        .foregroundStyle(.secondary)

                    Chart(metrics.trendSeries) { point in
                        let distractions = point.metrics["distractions"] ?? 0
                        BarMark(
                            x: .value("Session", chartDate(point.observedAt)),
                            y: .value("Distractions", distractions)
                        )
                        .foregroundStyle(
                            distractions == 0
                                ? Color.accentColor.opacity(0.45)
                                : Color.orange.opacity(0.85)
                        )
                        .cornerRadius(6)
                    }
                    .chartXAxis {
                        AxisMarks(values: .automatic(desiredCount: 6)) { value in
                            AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                                .foregroundStyle(Color.primary.opacity(0.08))
                            AxisValueLabel {
                                if let date = value.as(Date.self) {
                                    Text(date, format: .dateTime.month(.abbreviated).day())
                                }
                            }
                        }
                    }
                    .frame(height: 240)

                    if let noisiest = metrics.trendSeries.max(by: {
                        ($0.metrics["distractions"] ?? 0) < ($1.metrics["distractions"] ?? 0)
                    }) {
                        HStack {
                            Text("Noisiest block")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(noisiest.title)
                                .font(.caption.weight(.semibold))
                        }
                    }
                }
            }
            .frame(maxWidth: 360)
        }
    }

    private func reflectionStage(_ metrics: IntentMetricsState) -> some View {
        InsightPanel {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Recent Reflections")
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                    Text("The text behind the numbers, so the charts stay grounded.")
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }

            if metrics.reflectionHighlights.isEmpty {
                Text("Reflection highlights show up here once reviewed blocks start carrying notes.")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 12)
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 250, maximum: 360), spacing: 16)],
                    spacing: 16
                ) {
                    ForEach(metrics.reflectionHighlights) { item in
                        ReflectionHighlightCard(item: item)
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        InsightPanel {
            VStack(alignment: .leading, spacing: 14) {
                Text("No reviewed blocks yet")
                    .font(.system(size: 28, weight: .bold, design: .rounded))

                Text("Once you submit a few post-session reflections, this tab turns into the trend board for your own work patterns.")
                    .foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    Label("Review sessions from the dashboard", systemImage: "rectangle.and.pencil.and.ellipsis")
                    Label("Refresh metrics after a few reviews", systemImage: "arrow.clockwise")
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: 220)
        }
    }

    private func signalSelector(_ signals: [IntentSignalAverage]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(signals.prefix(8)) { signal in
                    Button {
                        selectedSignalKey = signal.key
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(signal.title)
                                .font(.caption.weight(.semibold))
                            Text(formatScore(signal.average))
                                .font(.system(size: 18, weight: .black, design: .rounded))
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(
                                    resolvedSignalKeyAvailable(signal.key, in: signals)
                                    ? (resolvedSignalKey(from: model.metricsState) == signal.key
                                        ? Color.accentColor.opacity(0.18)
                                        : Color.primary.opacity(0.05))
                                    : Color.primary.opacity(0.03)
                                )
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func resolvedSignalKey(from metrics: IntentMetricsState?) -> String {
        guard let metrics else {
            return selectedSignalKey
        }

        if metrics.signalAverages.contains(where: { $0.key == selectedSignalKey }) {
            return selectedSignalKey
        }

        return metrics.signalAverages.first?.key ?? selectedSignalKey
    }

    private func resolvedSignalKeyAvailable(_ key: String, in signals: [IntentSignalAverage]) -> Bool {
        signals.contains(where: { $0.key == key })
    }

    private func heroNarrative(for metrics: IntentMetricsState) -> String {
        let strongest = metrics.signalAverages.max { left, right in
            left.average < right.average
        }?.title ?? "Work quality"
        let weakest = metrics.signalAverages.min { left, right in
            left.average < right.average
        }?.title ?? "Focus"
        let category = metrics.dominantCategory?.capitalized ?? "mixed work"
        return "\(strongest) is carrying the recent blocks. \(weakest) is the soft edge. \(category) is where most of the energy has been landing."
    }

    private func bestCadenceDay(in metrics: IntentMetricsState) -> String {
        guard let best = metrics.dailyVolume.max(by: { $0.reviewedCount < $1.reviewedCount }) else {
            return "—"
        }

        return chartDate(best.dayStart).formatted(.dateTime.month(.abbreviated).day())
    }

    private func focusRunwayLabel(in metrics: IntentMetricsState) -> String {
        let values = metrics.dailyVolume.compactMap(\.averageFocus)
        guard !values.isEmpty else {
            return "—"
        }

        let average = values.reduce(0, +) / Double(values.count)
        return formatScore(average)
    }

    private func reviewDensityLabel(in metrics: IntentMetricsState) -> String {
        guard !metrics.dailyVolume.isEmpty else {
            return "—"
        }

        let totalReviews = metrics.dailyVolume.reduce(0) { $0 + $1.reviewedCount }
        let density = Double(totalReviews) / Double(metrics.dailyVolume.count)
        return formatScore(density)
    }

    private func durationText(_ milliseconds: Int) -> String {
        guard milliseconds > 0 else {
            return "0m"
        }

        let totalMinutes = milliseconds / 60_000
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60

        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }

        return "\(minutes)m"
    }

    private func relativeText(from milliseconds: Int) -> String {
        let date = chartDate(milliseconds)
        return Self.relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    private func chartDate(_ milliseconds: Int) -> Date {
        Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1000)
    }

    private func formatScore(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()
}

private struct InsightPanel<Content: View>: View {
    let padding: CGFloat
    let content: Content

    init(
        padding: CGFloat = 22,
        @ViewBuilder content: () -> Content
    ) {
        self.padding = padding
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            content
        }
        .padding(padding)
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

private struct InsightMetricCard: View {
    let title: String
    let value: String
    let caption: String
    let tone: Color
    let systemImage: String

    var body: some View {
        InsightPanel {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    Label(title, systemImage: systemImage)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    Text(value)
                        .font(.system(size: 28, weight: .black, design: .rounded))

                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(tone.opacity(0.18))
                    .frame(width: 44, height: 44)
                    .overlay(
                        Image(systemName: systemImage)
                            .font(.headline.weight(.bold))
                            .foregroundStyle(tone)
                    )
            }
        }
    }
}

private struct HighlightPill: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.58))
            Text(value)
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            Capsule(style: .continuous)
                .fill(Color.white.opacity(0.12))
        )
    }
}

private struct MetricsWindowPicker: View {
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

private struct SnapshotChip: View {
    let title: String
    let value: String
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.72))
            Text(value)
                .font(.system(size: 20, weight: .black, design: .rounded))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(accent.opacity(0.14))
        )
    }
}

private struct StatCallout: View {
    let title: String
    let value: String
    let caption: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 24, weight: .black, design: .rounded))
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
    }
}

private struct SignalBarRow: View {
    let signal: IntentSignalAverage

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(signal.title)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if let delta = signal.deltaFromPrevious {
                    Text(delta >= 0 ? "+\(String(format: "%.1f", delta))" : String(format: "%.1f", delta))
                        .font(.caption.weight(.bold))
                        .foregroundStyle(delta >= 0 ? Color.accentColor : Color.orange)
                }
                Text(String(format: "%.1f", signal.average))
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }

            GeometryReader { proxy in
                let fillWidth = max(12, proxy.size.width * CGFloat(signal.average / 10))

                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(Color.primary.opacity(0.08))

                    Capsule(style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [.accentColor, .mint],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: fillWidth)
                }
            }
            .frame(height: 12)

            Text("\(signal.count) reviewed blocks")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct ReflectionHighlightCard: View {
    let item: IntentReflectionHighlight

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title)
                        .font(.headline)
                        .lineLimit(2)

                    Text(item.taskCategory.capitalized)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }

            if !item.whatWentWell.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Went well")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Color.accentColor)
                    Text(item.whatWentWell)
                        .font(.subheadline)
                        .foregroundStyle(.primary.opacity(0.86))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if !item.whatDidntGoWell.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Did not go well")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.orange)
                    Text(item.whatDidntGoWell)
                        .font(.subheadline)
                        .foregroundStyle(.primary.opacity(0.82))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 8) {
                ReflectionMetricTag(label: "Focus", value: item.focus)
                ReflectionMetricTag(label: "Energy", value: item.energy)
                ReflectionMetricTag(label: "Distract.", value: item.distractions)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.primary.opacity(0.045))
        )
    }
}

private struct ReflectionMetricTag: View {
    let label: String
    let value: Int?

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value.map(String.init) ?? "—")
                .fontWeight(.bold)
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            Capsule(style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
    }
}
