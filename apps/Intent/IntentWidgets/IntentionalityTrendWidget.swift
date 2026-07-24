import AppIntents
import Charts
import SwiftUI
import WidgetKit

enum IntentTrendRange: Int, CaseIterable, AppEnum {
    case week = 7
    case month = 30
    case quarter = 90

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Trend range"
    static let caseDisplayRepresentations: [IntentTrendRange: DisplayRepresentation] = [
        .week: "7 days",
        .month: "30 days",
        .quarter: "90 days",
    ]

    var label: String {
        "\(rawValue)D"
    }
}

struct SetIntentTrendRangeIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Intentionality Trend Range"
    static let isDiscoverable = false

    @Parameter(title: "Range")
    var range: IntentTrendRange

    init() {}

    init(range: IntentTrendRange) {
        self.range = range
    }

    func perform() async throws -> some IntentResult {
        IntentWidgetShared.saveTrendRangeDays(range.rawValue)
        return .result()
    }
}

struct IntentionalityTrendEntry: TimelineEntry {
    let date: Date
    let snapshot: IntentIntentionalityState?
    let rangeDays: Int
    let isSample: Bool
}

struct IntentionalityTrendProvider: TimelineProvider {
    func placeholder(in context: Context) -> IntentionalityTrendEntry {
        IntentionalityTrendEntry(date: Date(), snapshot: .sample, rangeDays: 30, isSample: true)
    }

    func getSnapshot(in context: Context, completion: @escaping (IntentionalityTrendEntry) -> Void) {
        if context.isPreview {
            completion(placeholder(in: context))
            return
        }
        completion(currentEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<IntentionalityTrendEntry>) -> Void) {
        let entry = currentEntry()
        let refresh = Calendar.current.date(byAdding: .minute, value: 30, to: entry.date)
            ?? entry.date.addingTimeInterval(1800)
        completion(Timeline(entries: [entry], policy: .after(refresh)))
    }

    private func currentEntry() -> IntentionalityTrendEntry {
        IntentionalityTrendEntry(
            date: Date(),
            snapshot: IntentWidgetShared.loadSnapshot(),
            rangeDays: IntentWidgetShared.loadTrendRangeDays(),
            isSample: false
        )
    }
}

struct IntentionalityTrendWidget: Widget {
    let kind = IntentWidgetShared.trendWidgetKind

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: IntentionalityTrendProvider()) { entry in
            IntentionalityTrendView(entry: entry)
                .containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("Intentionality Trend")
        .description("Daily averages over the last 7, 30, or 90 days.")
        .supportedFamilies([.systemMedium, .systemLarge, .systemExtraLarge])
    }
}

struct IntentionalityTrendView: View {
    @Environment(\.widgetFamily) private var family

    let entry: IntentionalityTrendEntry

    private struct DayPoint: Identifiable {
        let day: Date
        let average: Double
        let count: Int

        var id: Date { day }
    }

    var body: some View {
        if let snapshot = entry.snapshot {
            trendContent(snapshot)
        } else {
            emptyState
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "chart.bar.fill")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("Open Intent to sync your intentionality data.")
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
    }

    private func trendContent(_ snapshot: IntentIntentionalityState) -> some View {
        let points = dayPoints(in: snapshot, daysBack: entry.rangeDays, endingAt: entry.date)
        let previous = dayPoints(
            in: snapshot,
            daysBack: entry.rangeDays,
            endingAt: Calendar.current.date(
                byAdding: .day,
                value: -entry.rangeDays,
                to: entry.date
            ) ?? entry.date
        )
        let average = windowAverage(points)
        let previousAverage = windowAverage(previous)

        return VStack(alignment: .leading, spacing: 10) {
            header

            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(average.map { String(format: "%.1f", $0) } ?? "--")
                    .font(.system(size: 34, weight: .black, design: .rounded))
                    .foregroundStyle(IntentWidgetShared.scoreColor(average ?? 3))

                Text("avg / 5")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let average, let previousAverage {
                    let delta = average - previousAverage
                    Label(
                        String(format: "%@%.1f vs prior \(entry.rangeDays)d", delta >= 0 ? "+" : "", delta),
                        systemImage: delta >= 0 ? "arrow.up.right" : "arrow.down.right"
                    )
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(delta >= 0 ? .green : .red)
                }

                Spacer(minLength: 0)

                Text("\(points.count) of \(entry.rangeDays) days logged")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            chart(points: points, average: average)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        HStack(alignment: .center) {
            Text(entry.isSample ? "INTENTIONALITY (SAMPLE)" : "INTENTIONALITY")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)

            Spacer(minLength: 8)

            HStack(spacing: 4) {
                ForEach(IntentTrendRange.allCases, id: \.rawValue) { range in
                    Button(intent: SetIntentTrendRangeIntent(range: range)) {
                        Text(range.label)
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(
                                        range.rawValue == entry.rangeDays
                                            ? Color.accentColor.opacity(0.22)
                                            : Color.primary.opacity(0.06)
                                    )
                            )
                            .foregroundStyle(
                                range.rawValue == entry.rangeDays ? Color.accentColor : Color.secondary
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func chart(points: [DayPoint], average: Double?) -> some View {
        let calendar = Calendar.current
        let end = calendar.startOfDay(for: entry.date).addingTimeInterval(24 * 60 * 60)
        let start = calendar.date(byAdding: .day, value: -entry.rangeDays, to: end) ?? end

        return Chart {
            ForEach(points) { point in
                BarMark(
                    x: .value("Day", point.day, unit: .day),
                    y: .value("Average", point.average)
                )
                .cornerRadius(2)
                .foregroundStyle(IntentWidgetShared.scoreColor(point.average))
            }

            if let average {
                RuleMark(y: .value("Window average", average))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .foregroundStyle(.secondary.opacity(0.5))
            }
        }
        .chartXScale(domain: start...end)
        .chartYScale(domain: 0...5)
        .chartXAxis {
            AxisMarks(values: xAxisValues(from: start, to: end)) { _ in
                AxisGridLine().foregroundStyle(.quaternary)
                AxisValueLabel(format: xAxisFormat, centered: entry.rangeDays == 7)
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary)
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: [1, 3, 5]) { _ in
                AxisGridLine().foregroundStyle(.quaternary)
                AxisValueLabel()
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var xAxisFormat: Date.FormatStyle {
        switch entry.rangeDays {
        case 7:
            return .dateTime.weekday(.abbreviated)
        case 30:
            return .dateTime.month(.abbreviated).day()
        default:
            return .dateTime.month(.abbreviated)
        }
    }

    private func xAxisValues(from start: Date, to end: Date) -> AxisMarkValues {
        switch entry.rangeDays {
        case 7:
            return .stride(by: .day)
        case 30:
            return .stride(by: .day, count: 7)
        default:
            return .stride(by: .month)
        }
    }

    private func dayPoints(
        in snapshot: IntentIntentionalityState,
        daysBack: Int,
        endingAt end: Date
    ) -> [DayPoint] {
        let calendar = Calendar.current
        let endOfWindow = calendar.startOfDay(for: end).addingTimeInterval(24 * 60 * 60)
        guard
            let startOfWindow = calendar.date(byAdding: .day, value: -daysBack, to: endOfWindow)
        else {
            return []
        }

        return (snapshot.dailyAverages ?? [])
            .compactMap { day -> DayPoint? in
                guard let average = day.average else {
                    return nil
                }
                let date = Date(timeIntervalSince1970: day.dayStartMs / 1000)
                guard date >= startOfWindow, date < endOfWindow else {
                    return nil
                }
                return DayPoint(day: date, average: average, count: day.count)
            }
            .sorted { $0.day < $1.day }
    }

    // weight by logged hours so a 2-hour day does not count like a full day
    private func windowAverage(_ points: [DayPoint]) -> Double? {
        let totalCount = points.reduce(0) { $0 + $1.count }
        guard totalCount > 0 else {
            return nil
        }
        let weightedSum = points.reduce(0.0) { $0 + $1.average * Double($1.count) }
        return weightedSum / Double(totalCount)
    }
}
