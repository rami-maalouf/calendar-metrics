import SwiftUI
import WidgetKit

struct IntentionalityEntry: TimelineEntry {
    let date: Date
    let snapshot: IntentIntentionalityState?
    let isSample: Bool
}

struct IntentionalityProvider: TimelineProvider {
    func placeholder(in context: Context) -> IntentionalityEntry {
        IntentionalityEntry(date: Date(), snapshot: .sample, isSample: true)
    }

    func getSnapshot(in context: Context, completion: @escaping (IntentionalityEntry) -> Void) {
        if context.isPreview {
            completion(IntentionalityEntry(date: Date(), snapshot: .sample, isSample: true))
            return
        }
        completion(currentEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<IntentionalityEntry>) -> Void) {
        let entry = currentEntry()
        let refresh = Calendar.current.date(byAdding: .minute, value: 30, to: entry.date)
            ?? entry.date.addingTimeInterval(1800)
        completion(Timeline(entries: [entry], policy: .after(refresh)))
    }

    private func currentEntry() -> IntentionalityEntry {
        IntentionalityEntry(
            date: Date(),
            snapshot: IntentWidgetShared.loadSnapshot(),
            isSample: false
        )
    }
}

struct IntentionalityTodayWidget: Widget {
    let kind = "IntentionalityToday"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: IntentionalityProvider()) { entry in
            IntentionalityWidgetView(entry: entry)
                .containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("Intentionality")
        .description("Today's hourly intentionality at a glance.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct IntentionalityWidgetView: View {
    @Environment(\.widgetFamily) private var family

    let entry: IntentionalityEntry

    var body: some View {
        if let snapshot = entry.snapshot {
            switch family {
            case .systemMedium:
                mediumView(snapshot)
            default:
                smallView(snapshot)
            }
        } else {
            emptyState
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "target")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("Open Intent to sync your intentionality data.")
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
    }

    private func smallView(_ snapshot: IntentIntentionalityState) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            header
            Spacer(minLength: 0)
            scoreLine(snapshot)
            deltaLine(snapshot)
            if let streak = snapshot.currentStreakDays, streak > 0 {
                Label("\(streak)-day streak", systemImage: "flame.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            Spacer(minLength: 0)
            hourStrip(snapshot)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func mediumView(_ snapshot: IntentIntentionalityState) -> some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                header
                Spacer(minLength: 0)
                scoreLine(snapshot)
                deltaLine(snapshot)
                if let streak = snapshot.currentStreakDays, streak > 0 {
                    Label("\(streak)-day streak", systemImage: "flame.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                hourGrid(snapshot)
                if let best = snapshot.bestHourOfDay {
                    Text("Best hour: \(best.label)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if let rate = snapshot.responseRate7d {
                    Text("Logged \(Int(rate.rounded()))% of hours this week")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var header: some View {
        Text(entry.isSample ? "INTENTIONALITY (SAMPLE)" : "INTENTIONALITY")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    private func scoreLine(_ snapshot: IntentIntentionalityState) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(formatScore(snapshot.todayAverage))
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .foregroundStyle(scoreColor(snapshot.todayAverage ?? 0))
            Text("today")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func deltaLine(_ snapshot: IntentIntentionalityState) -> some View {
        if let delta = snapshot.deltaFromYesterday {
            let up = delta >= 0
            Label(
                String(format: "%@%.1f vs yesterday", up ? "+" : "", delta),
                systemImage: up ? "arrow.up.right" : "arrow.down.right"
            )
            .font(.caption2)
            .foregroundStyle(up ? .green : .red)
        }
    }

    private func hourStrip(_ snapshot: IntentIntentionalityState) -> some View {
        let scores = hourScores(snapshot)
        return HStack(spacing: 2) {
            ForEach(0..<24, id: \.self) { hour in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(scores[hour].map { scoreColor($0) } ?? Color.secondary.opacity(0.2))
                    .frame(height: 8)
            }
        }
    }

    private func hourGrid(_ snapshot: IntentIntentionalityState) -> some View {
        let scores = hourScores(snapshot)
        let columns = Array(repeating: GridItem(.flexible(), spacing: 3), count: 12)
        return LazyVGrid(columns: columns, spacing: 3) {
            ForEach(0..<24, id: \.self) { hour in
                RoundedRectangle(cornerRadius: 3)
                    .fill(scores[hour].map { scoreColor($0) } ?? Color.secondary.opacity(0.2))
                    .frame(height: 18)
                    .overlay {
                        if hour % 6 == 0 {
                            Text(hourTickLabel(hour))
                                .font(.system(size: 7))
                                .foregroundStyle(.secondary)
                        }
                    }
            }
        }
    }

    private func hourScores(_ snapshot: IntentIntentionalityState) -> [Double?] {
        var scores = [Double?](repeating: nil, count: 24)
        for entry in snapshot.todayEntries where (0..<24).contains(entry.hour) {
            scores[entry.hour] = entry.score
        }
        return scores
    }

    private func hourTickLabel(_ hour: Int) -> String {
        switch hour {
        case 0: return "12a"
        case 12: return "12p"
        case ..<12: return "\(hour)a"
        default: return "\(hour - 12)p"
        }
    }

    private func formatScore(_ value: Double?) -> String {
        guard let value else { return "--" }
        return String(format: "%.1f", value)
    }

    private func scoreColor(_ score: Double) -> Color {
        IntentWidgetShared.scoreColor(score)
    }
}
