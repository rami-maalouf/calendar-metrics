import AppIntents
import Charts
import SwiftUI
import WidgetKit

struct SetTrackedHoursRangeIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Tracked Hours Range"
    static let isDiscoverable = false

    @Parameter(title: "Range")
    var range: IntentTrendRange

    init() {}

    init(range: IntentTrendRange) {
        self.range = range
    }

    func perform() async throws -> some IntentResult {
        IntentWidgetShared.saveTrackedHoursRangeDays(range.rawValue)
        return .result()
    }
}

struct IntentTrackedHoursEntry: TimelineEntry {
    let date: Date
    let snapshot: IntentTrackedHoursSnapshot?
    let rangeDays: Int
    let isSample: Bool
}

struct IntentTrackedHoursProvider: TimelineProvider {
    func placeholder(in context: Context) -> IntentTrackedHoursEntry {
        IntentTrackedHoursEntry(date: Date(), snapshot: .sample, rangeDays: 30, isSample: true)
    }

    func getSnapshot(in context: Context, completion: @escaping (IntentTrackedHoursEntry) -> Void) {
        if context.isPreview {
            completion(placeholder(in: context))
            return
        }
        completion(currentEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<IntentTrackedHoursEntry>) -> Void) {
        let entry = currentEntry()
        let refresh = Calendar.current.date(byAdding: .minute, value: 30, to: entry.date)
            ?? entry.date.addingTimeInterval(1800)
        completion(Timeline(entries: [entry], policy: .after(refresh)))
    }

    private func currentEntry() -> IntentTrackedHoursEntry {
        IntentTrackedHoursEntry(
            date: Date(),
            snapshot: IntentWidgetShared.loadTrackedHours(),
            rangeDays: IntentWidgetShared.loadTrackedHoursRangeDays(),
            isSample: false
        )
    }
}

struct IntentTrackedHoursWidget: Widget {
    let kind = IntentWidgetShared.trackedHoursWidgetKind

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: IntentTrackedHoursProvider()) { entry in
            IntentTrackedHoursView(entry: entry)
                .containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("Tracked Hours")
        .description("Deep work hours tracked per day over 7, 30, or 90 days.")
        .supportedFamilies([.systemMedium, .systemLarge, .systemExtraLarge])
    }
}

struct IntentTrackedHoursView: View {
    let entry: IntentTrackedHoursEntry

    // single hue: hours are a magnitude, not a good/bad scale
    private let barColor = Color(red: 0.08, green: 0.65, blue: 0.60)

    var body: some View {
        if let snapshot = entry.snapshot, !snapshot.days.isEmpty {
            content(snapshot)
        } else {
            emptyState
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "clock.fill")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("Open Intent to sync your tracked hours.")
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
    }

    private func content(_ snapshot: IntentTrackedHoursSnapshot) -> some View {
        let days = windowDays(in: snapshot, daysBack: entry.rangeDays, endingAt: entry.date)
        let previous = windowDays(
            in: snapshot,
            daysBack: entry.rangeDays,
            endingAt: Calendar.current.date(
                byAdding: .day,
                value: -entry.rangeDays,
                to: entry.date
            ) ?? entry.date
        )
        let totalHours = days.reduce(0.0) { $0 + $1.hours }
        let previousTotal = previous.reduce(0.0) { $0 + $1.hours }
        let dailyAverage = totalHours / Double(entry.rangeDays)

        return VStack(alignment: .leading, spacing: 10) {
            header

            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(hoursLabel(totalHours))
                    .font(.system(size: 34, weight: .black, design: .rounded))
                    .foregroundStyle(barColor)

                Text(String(format: "%@ / day avg", hoursLabel(dailyAverage)))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if !previous.isEmpty {
                    let delta = totalHours - previousTotal
                    Label(
                        String(format: "%@%@ vs prior %dd", delta >= 0 ? "+" : "-", hoursLabel(abs(delta)), entry.rangeDays),
                        systemImage: delta >= 0 ? "arrow.up.right" : "arrow.down.right"
                    )
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(delta >= 0 ? .green : .red)
                }

                Spacer(minLength: 0)

                Text("\(days.count) active days of \(entry.rangeDays)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            chart(days: days, dailyAverage: dailyAverage)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        HStack(alignment: .center) {
            Text(entry.isSample ? "TRACKED HOURS (SAMPLE)" : "TRACKED HOURS")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)

            Spacer(minLength: 8)

            HStack(spacing: 4) {
                ForEach(IntentTrendRange.allCases, id: \.rawValue) { range in
                    Button(intent: SetTrackedHoursRangeIntent(range: range)) {
                        Text(range.label)
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(
                                        range.rawValue == entry.rangeDays
                                            ? barColor.opacity(0.22)
                                            : Color.primary.opacity(0.06)
                                    )
                            )
                            .foregroundStyle(
                                range.rawValue == entry.rangeDays ? barColor : Color.secondary
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func chart(days: [IntentTrackedHoursSnapshot.Day], dailyAverage: Double) -> some View {
        let calendar = Calendar.current
        let end = calendar.startOfDay(for: entry.date).addingTimeInterval(24 * 60 * 60)
        let start = calendar.date(byAdding: .day, value: -entry.rangeDays, to: end) ?? end
        let ceiling = max(4, (days.map(\.hours).max() ?? 0) * 1.15)

        return Chart {
            ForEach(days) { day in
                BarMark(
                    x: .value("Day", Date(timeIntervalSince1970: day.dayStartMs / 1000), unit: .day),
                    y: .value("Hours", day.hours)
                )
                .cornerRadius(2)
                .foregroundStyle(barColor)
            }

            if dailyAverage > 0 {
                RuleMark(y: .value("Daily average", dailyAverage))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .foregroundStyle(.secondary.opacity(0.5))
            }
        }
        .chartXScale(domain: start...end)
        .chartYScale(domain: 0...ceiling)
        .chartXAxis {
            AxisMarks(values: xAxisValues) { _ in
                AxisGridLine().foregroundStyle(.quaternary)
                AxisValueLabel(format: xAxisFormat, centered: entry.rangeDays == 7)
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary)
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { _ in
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

    private var xAxisValues: AxisMarkValues {
        switch entry.rangeDays {
        case 7:
            return .stride(by: .day)
        case 30:
            return .stride(by: .day, count: 7)
        default:
            return .stride(by: .month)
        }
    }

    private func windowDays(
        in snapshot: IntentTrackedHoursSnapshot,
        daysBack: Int,
        endingAt end: Date
    ) -> [IntentTrackedHoursSnapshot.Day] {
        let calendar = Calendar.current
        let endOfWindow = calendar.startOfDay(for: end).addingTimeInterval(24 * 60 * 60)
        guard
            let startOfWindow = calendar.date(byAdding: .day, value: -daysBack, to: endOfWindow)
        else {
            return []
        }

        return snapshot.days
            .filter { day in
                let date = Date(timeIntervalSince1970: day.dayStartMs / 1000)
                return date >= startOfWindow && date < endOfWindow
            }
            .sorted { $0.dayStartMs < $1.dayStartMs }
    }

    private func hoursLabel(_ hours: Double) -> String {
        if hours >= 10 {
            return String(format: "%.0fh", hours)
        }
        if hours >= 1 {
            return String(format: "%.1fh", hours)
        }
        return String(format: "%.0fm", hours * 60)
    }
}
