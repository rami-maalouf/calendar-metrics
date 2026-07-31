//
//  ReviewSheetView.swift
//  Intent
//
//  Created by Codex on 2026-03-10.
//

import AppKit
import SwiftUI

struct ReviewSheetView: View {
    @Binding var context: IntentReviewContext
    let isSubmitting: Bool
    let aiConfigured: Bool
    let taskCategorySuggestions: [String]
    let projectNameSuggestions: [String]
    let onExtractCapture: (String) async throws -> IntentReviewAIPatch
    let onSubmit: () -> Void
    let onDismiss: () -> Void

    @State private var isQuickCaptureExpanded = false
    @State private var quickCaptureText = ""
    @State private var isExtractingCapture = false
    @State private var quickCaptureNotice: String?
    @State private var quickCaptureError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                headerSection
                quickCaptureSection
                projectSection
                categorySection
                numericSignalsSection
                countSignalsSection
                reflectionSection
                footerSection
            }
            .padding(28)
        }
        .frame(minWidth: 760, minHeight: 900)
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: context.id) {
            quickCaptureText = ""
            quickCaptureNotice = nil
            quickCaptureError = nil
            isQuickCaptureExpanded = false
        }
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Post-Session Reflection")
                .font(.system(size: 28, weight: .black, design: .rounded))

            Text(context.session.displayTitle)
                .font(.title3.bold())

            Text(sessionWindow)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text("Optional. Press Esc to skip - it won't come back.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var quickCaptureSection: some View {
        ReviewSectionCard(
            title: "Quick Capture",
            subtitle: "Optional. Dump the raw note once and let AI map it into the review."
        ) {
            VStack(alignment: .leading, spacing: 14) {
                Button {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) {
                        isQuickCaptureExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "wand.and.stars.inverse")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 36, height: 36)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(
                                        LinearGradient(
                                            colors: [.accentColor, .mint],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )
                                    )
                            )

                        VStack(alignment: .leading, spacing: 3) {
                            Text(isQuickCaptureExpanded ? "Hide AI capture" : "Show AI capture")
                                .font(.headline)
                            Text("Freeform note in, structured review out.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Image(systemName: isQuickCaptureExpanded ? "chevron.up" : "chevron.down")
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if isQuickCaptureExpanded {
                    VStack(alignment: .leading, spacing: 14) {
                        FlexibleBadgeRow(
                            items: [
                                "task category",
                                "signals",
                                "distractions",
                                "what went well",
                                "what didn't go well",
                            ]
                        )

                        ZStack(alignment: .topLeading) {
                            TextEditor(text: $quickCaptureText)
                                .scrollContentBackground(.hidden)
                                .frame(minHeight: 150)
                                .padding(10)
                                .background(fieldBackground)

                            if quickCaptureText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                Text("Anything you want to remember about the block: what you actually did, where you drifted, what felt strong, what felt off.")
                                    .font(.body)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 24)
                                    .padding(.vertical, 22)
                                    .allowsHitTesting(false)
                            }
                        }

                        if !aiConfigured {
                            Text("Add your OpenAI API key in Settings to use AI quick capture.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }

                        if let quickCaptureNotice, !quickCaptureNotice.isEmpty {
                            Text(quickCaptureNotice)
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(Color.accentColor)
                        }

                        if let quickCaptureError, !quickCaptureError.isEmpty {
                            Text(quickCaptureError)
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.red)
                        }

                        HStack {
                            Button("Clear") {
                                quickCaptureText = ""
                                quickCaptureNotice = nil
                                quickCaptureError = nil
                            }
                            .disabled(quickCaptureText.isEmpty || isExtractingCapture)

                            Spacer()

                            Button {
                                Task {
                                    await extractQuickCapture()
                                }
                            } label: {
                                HStack(spacing: 8) {
                                    if isExtractingCapture {
                                        ProgressView()
                                            .controlSize(.small)
                                    }

                                    Text(isExtractingCapture ? "Extracting..." : "Extract into review")
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(
                                isExtractingCapture ||
                                !aiConfigured ||
                                quickCaptureText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            )
                        }
                    }
                    .transition(
                        .asymmetric(
                            insertion: .move(edge: .top).combined(with: .opacity),
                            removal: .opacity
                        )
                    )
                }
            }
        }
    }

    private var projectSection: some View {
        ReviewSectionCard(title: "Project", subtitle: "Optional. Automatically synced from Toggl, but can be overridden here.") {
            TextField("Project name", text: draftBinding(\.projectName))
                .textFieldStyle(.roundedBorder)
                .textInputSuggestions(filteredProjectNameSuggestions, id: \.self) { suggestion in
                    Label(suggestion, systemImage: "arrow.turn.down.right")
                        .textInputCompletion(suggestion)
                }
        }
    }

    private var categorySection: some View {
        ReviewSectionCard(title: "Task Category", subtitle: "Open-ended, with suggestions from prior completions.") {
            TextField("Task category", text: draftBinding(\.taskCategory))
                .textFieldStyle(.roundedBorder)
                .textInputSuggestions(filteredTaskCategorySuggestions, id: \.self) { suggestion in
                    Label(suggestion, systemImage: "arrow.turn.down.right")
                        .textInputCompletion(suggestion)
                }
        }
    }

    private var numericSignalsSection: some View {
        ReviewSectionCard(title: "Signals", subtitle: "Rate each signal from 0 to 10.") {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 190, maximum: 260), spacing: 14)],
                spacing: 14
            ) {
                ForEach(IntentReviewCatalog.numericMetricDefinitions) { metric in
                    MetricSliderCard(
                        title: metric.title,
                        value: numericMetricBinding(for: metric.id),
                        tint: tint(for: metric.id)
                    )
                }
            }
        }
    }

    private var countSignalsSection: some View {
        ReviewSectionCard(title: "Counts", subtitle: "Track discrete events that affected the block.") {
            VStack(spacing: 14) {
                ForEach(IntentReviewCatalog.countMetricDefinitions) { metric in
                    CountMetricSliderRow(
                        title: metric.title,
                        value: countMetricBinding(for: metric.id)
                    )
                }
            }
        }
    }

    private var reflectionSection: some View {
        ReviewSectionCard(title: "Reflection", subtitle: "Keep it honest, concrete, and causal.") {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("What went well. And why")
                        .font(.headline)
                    TextEditor(text: draftBinding(\.whatWentWell))
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 120)
                        .padding(10)
                        .background(fieldBackground)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("What didn't go well. And why")
                        .font(.headline)
                    TextEditor(text: draftBinding(\.whatDidntGoWell))
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 120)
                        .padding(10)
                        .background(fieldBackground)
                }
            }
        }
    }

    private var footerSection: some View {
        HStack {
            Button("Skip", role: .cancel) {
                onDismiss()
            }
            .keyboardShortcut(.cancelAction)
            .help("Dismiss without saving. Escape also skips.")

            Text("Esc")
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
                .padding(.leading, 4)

            Spacer()

            Button("Save review") {
                onSubmit()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(isSubmitting || !context.draft.hasMeaningfulContent)
        }
    }

    private var fieldBackground: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(Color.primary.opacity(0.04))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )
    }

    private var filteredTaskCategorySuggestions: [String] {
        let trimmed = context.draft.taskCategory.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = trimmed.lowercased()

        return taskCategorySuggestions
            .filter { suggestion in
                guard suggestion.lowercased() != lowered else {
                    return false
                }

                if lowered.isEmpty {
                    return true
                }

                return suggestion.lowercased().contains(lowered)
            }
            .prefix(8)
            .map { $0 }
    }

    private var filteredProjectNameSuggestions: [String] {
        let trimmed = context.draft.projectName.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = trimmed.lowercased()

        return projectNameSuggestions
            .filter { suggestion in
                guard suggestion.lowercased() != lowered else {
                    return false
                }

                if lowered.isEmpty {
                    return true
                }

                return suggestion.lowercased().contains(lowered)
            }
            .prefix(8)
            .map { $0 }
    }

    private var sessionWindow: String {
        let start = Date(timeIntervalSince1970: TimeInterval(context.session.startTimeMs) / 1000)
        let stop = context.session.stopTimeMs.map {
            Date(timeIntervalSince1970: TimeInterval($0) / 1000)
        }
        let startText = Self.timeFormatter.string(from: start)
        let stopText = stop.map { Self.timeFormatter.string(from: $0) } ?? "Running"
        return "\(startText) - \(stopText)"
    }

    @MainActor
    private func extractQuickCapture() async {
        guard !isExtractingCapture else {
            return
        }

        isExtractingCapture = true
        quickCaptureNotice = nil
        quickCaptureError = nil

        defer {
            isExtractingCapture = false
        }

        do {
            let patch = try await onExtractCapture(quickCaptureText)

            guard !patch.isEmpty else {
                quickCaptureNotice = "Nothing was strong enough to apply yet. Add a little more detail or set the fields manually."
                return
            }

            context.draft.apply(patch)

            let labels = Array(patch.appliedLabels.prefix(4))
            let suffix = patch.appliedLabels.count > labels.count
                ? " +\(patch.appliedLabels.count - labels.count) more"
                : ""
            quickCaptureNotice = "Applied \(labels.joined(separator: ", "))\(suffix)."
        } catch {
            quickCaptureError = error.localizedDescription
        }
    }

    private func tint(for metricID: String) -> Color {
        switch metricID {
        case "focus":
            return .accentColor
        case "energy":
            return .orange
        case "discipline":
            return .accentColor
        case "adherence":
            return .green
        case "intentionality":
            return .purple
        default:
            return .accentColor
        }
    }

    private func draftBinding<Value>(_ keyPath: WritableKeyPath<IntentReviewDraft, Value>) -> Binding<Value> {
        Binding(
            get: {
                context.draft[keyPath: keyPath]
            },
            set: { newValue in
                context.draft[keyPath: keyPath] = newValue
            }
        )
    }

    private func numericMetricBinding(for key: String) -> Binding<Int> {
        Binding(
            get: {
                context.draft.numericMetricValue(for: key)
            },
            set: { newValue in
                context.draft.setNumericMetricValue(newValue, for: key)
            }
        )
    }

    private func countMetricBinding(for key: String) -> Binding<Int> {
        Binding(
            get: {
                context.draft.countMetricValue(for: key)
            },
            set: { newValue in
                context.draft.setCountMetricValue(newValue, for: key)
            }
        )
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter
    }()
}

private struct FlexibleBadgeRow: View {
    let items: [String]

    var body: some View {
        FlowLayout(horizontalSpacing: 8, verticalSpacing: 8) {
            ForEach(items, id: \.self) { item in
                Text(item)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.primary.opacity(0.06))
                            .overlay(
                                Capsule(style: .continuous)
                                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                            )
                    )
            }
        }
    }
}

private struct ReviewSectionCard<Content: View>: View {
    let title: String
    let subtitle: String
    let content: Content

    init(
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.title3.bold())
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            content
        }
        .padding(22)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.regularMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                )
        )
    }
}

private struct MetricSliderCard: View {
    let title: String
    @Binding var value: Int
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(title)
                    .font(.headline)
                    .lineLimit(2)
                Spacer()
                Text("\(value)")
                    .font(.system(size: 24, weight: .black, design: .rounded))
                    .foregroundStyle(tint)
                    .monospacedDigit()
            }

            Slider(
                value: Binding(
                    get: { Double(value) },
                    set: { value = Int($0.rounded()) }
                ),
                in: 0 ... 10,
                step: 1
            )
            .tint(tint)

            HStack {
                Text("0")
                Spacer()
                Text("5")
                Spacer()
                Text("10")
            }
            .font(.footnote.monospaced())
            .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(tint.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(tint.opacity(0.16), lineWidth: 1)
                )
        )
    }
}

private struct CountMetricSliderRow: View {
    let title: String
    @Binding var value: Int

    private let presets = [0, 1, 2, 3, 5, 8, 10]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text("Count how many times it happened during the session.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Slider(
                    value: Binding(
                        get: { Double(value) },
                        set: { value = Int($0.rounded()) }
                    ),
                    in: 0 ... 10,
                    step: 1
                )
                .tint(.orange)

                Text(valueLabel)
                    .font(.system(size: 20, weight: .black, design: .rounded))
                    .monospacedDigit()
            }

            HStack(spacing: 8) {
                ForEach(presets, id: \.self) { preset in
                    Button(action: {
                        value = preset
                    }) {
                        Text(preset == 10 ? "10+" : "\(preset)")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                    }
                    .buttonStyle(.plain)
                    .background(
                        Capsule(style: .continuous)
                            .fill(value == preset ? Color.orange.opacity(0.18) : Color.primary.opacity(0.06))
                            .overlay(
                                Capsule(style: .continuous)
                                    .strokeBorder(
                                        value == preset ? Color.orange.opacity(0.32) : Color.primary.opacity(0.08),
                                        lineWidth: 1
                                    )
                            )
                    )
                    .foregroundStyle(value == preset ? Color.orange : .primary)
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.primary.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                )
        )
    }

    private var valueLabel: String {
        value >= 10 ? "10+" : "\(value)"
    }
}

private struct FlowLayout: Layout {
    let horizontalSpacing: CGFloat
    let verticalSpacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let maxWidth = proposal.width ?? 600
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > maxWidth, currentX > 0 {
                currentX = 0
                currentY += rowHeight + verticalSpacing
                rowHeight = 0
            }

            rowHeight = max(rowHeight, size.height)
            currentX += size.width + horizontalSpacing
        }

        return CGSize(width: maxWidth, height: currentY + rowHeight)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        var currentX = bounds.minX
        var currentY = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > bounds.maxX, currentX > bounds.minX {
                currentX = bounds.minX
                currentY += rowHeight + verticalSpacing
                rowHeight = 0
            }

            subview.place(
                at: CGPoint(x: currentX, y: currentY),
                proposal: ProposedViewSize(width: size.width, height: size.height)
            )

            rowHeight = max(rowHeight, size.height)
            currentX += size.width + horizontalSpacing
        }
    }
}
