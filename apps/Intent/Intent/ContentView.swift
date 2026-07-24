//
//  ContentView.swift
//  Intent
//
//  Created by Codex on 2026-03-10.
//

import AppKit
import SwiftUI

private enum IntentScreen: String, CaseIterable, Identifiable {
    case dashboard
    case visuals
    case screen
    case reports
    case metrics
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard:
            return "Dashboard"
        case .visuals:
            return "Visuals"
        case .screen:
            return "iPhone Screen"
        case .reports:
            return "Reports"
        case .metrics:
            return "Metrics"
        case .settings:
            return "Settings"
        }
    }

    var subtitle: String {
        switch self {
        case .dashboard:
            return "Live work ledger"
        case .visuals:
            return "The signals, big"
        case .screen:
            return "Phone hours and apps"
        case .reports:
            return "End-of-day wrap-ups"
        case .metrics:
            return "Patterns and trends"
        case .settings:
            return "Automation and wiring"
        }
    }

    var systemImage: String {
        switch self {
        case .dashboard:
            return "square.grid.2x2.fill"
        case .visuals:
            return "chart.bar.fill"
        case .screen:
            return "iphone"
        case .reports:
            return "doc.text.image.fill"
        case .metrics:
            return "chart.xyaxis.line"
        case .settings:
            return "slider.horizontal.3"
        }
    }
}

struct ContentView: View {
    @ObservedObject var model: IntentAppModel
    @State private var selection: IntentScreen = .dashboard

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(IntentScreen.allCases) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        Label(item.title, systemImage: item.systemImage)
                            .font(.headline)
                        Text(item.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 28)
                    }
                    .padding(.vertical, 6)
                    .tag(item)
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 240)
            .listStyle(.sidebar)
            .safeAreaInset(edge: .bottom) {
                sidebarFooter
                    .padding(12)
            }
        } detail: {
            ZStack {
                dashboardBackdrop

                switch selection {
                case .dashboard:
                    dashboardView
                case .visuals:
                    IntentVisualsView(model: model)
                case .screen:
                    IntentScreenTimeView(model: model)
                case .reports:
                    IntentReportsView(model: model)
                case .metrics:
                    IntentMetricsView(model: model)
                case .settings:
                    settingsView
                }
            }
        }
        .frame(minWidth: 1120, minHeight: 760)
        .sheet(
            isPresented: Binding(
                get: { model.activeReview != nil },
                set: { isPresented in
                    if !isPresented {
                        model.dismissReview()
                    }
                }
            )
        ) {
            if let reviewBinding = activeReviewBinding {
                ReviewSheetView(
                    context: reviewBinding,
                    isSubmitting: model.isSubmittingReview,
                    aiConfigured: model.isAIConfigured,
                    taskCategorySuggestions: taskCategorySuggestions,
                    projectNameSuggestions: projectNameSuggestions,
                    onExtractCapture: { text in
                        try await model.extractReviewDraft(
                            from: text,
                            for: reviewBinding.wrappedValue.session,
                            taskCategorySuggestions: taskCategorySuggestions
                        )
                    },
                    onSubmit: {
                        Task {
                            await model.submitActiveReview()
                        }
                    },
                    onDismiss: {
                        model.dismissReview()
                    }
                )
            } else {
                EmptyView()
            }
        }
        .task {
            if !model.configuration.isPaired {
                selection = .settings
            }
            model.start()
        }
        .task(id: selection) {
            switch selection {
            case .dashboard:
                await model.refreshDashboardNow()
                // streak badge reads metricsState.dailyDurationSeries; load it silently
                await model.refreshMetricsOnce()
            case .visuals, .metrics:
                await model.refreshMetricsNow()
            case .screen:
                await model.refreshScreenNow()
            case .reports, .settings:
                break
            }
        }
    }

    private var dashboardView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                dashboardHeader
                metricsGrid
                spotlightRow
                recentSessionsSection
                backendPulseSection
            }
            .padding(28)
        }
    }

    private var dashboardHeader: some View {
        DashboardPanel {
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Intent")
                        .font(.system(size: 42, weight: .black, design: .rounded))

                    Text(dashboardHeadline)
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)

                    if let latestReflectionNote {
                        Text("Latest note: \(latestReflectionNote)")
                            .font(.system(size: 14, weight: .medium, design: .rounded))
                            .foregroundStyle(.primary.opacity(0.85))
                            .padding(.top, 2)
                    }

                    if let latestDailyReport = model.latestDailyReport {
                        Text("Latest report: \(latestDailyReport.headline)")
                            .font(.system(size: 14, weight: .medium, design: .rounded))
                            .foregroundStyle(.primary.opacity(0.85))
                            .padding(.top, 2)
                    }
                }

                Spacer(minLength: 16)

                VStack(alignment: .trailing, spacing: 10) {
                    IntentStreakBadge(streak: trackingStreak)

                    HStack(spacing: 10) {
                        StatusBadge(
                            title: model.connectionStatus,
                            tone: model.connectionStatus == "Connected" ? .green : .orange
                        )
                        StatusBadge(
                            title: webhookBadgeTitle,
                            tone: webhookBadgeTone
                        )
                    }

                    HStack(spacing: 10) {
                        StatusBadge(
                            title: "\(model.pendingReviewsCount) review\(model.pendingReviewsCount == 1 ? "" : "s") waiting",
                            tone: model.pendingReviewsCount > 0 ? .yellow : .gray
                        )

                        if let topCategory {
                            StatusBadge(title: topCategory.capitalized, tone: .accentColor)
                        }
                    }
                }
            }
        }
    }

    private var metricsGrid: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 180, maximum: 280), spacing: 16)],
            spacing: 16
        ) {
            MetricCard(
                title: "Tracked Today",
                value: durationText(trackedTodayMs),
                caption: "\(todaySessions.count) session\(todaySessions.count == 1 ? "" : "s") logged",
                systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90",
                tone: .accentColor
            )

            MetricCard(
                title: "Sessions Closed",
                value: "\(completedTodayCount)",
                caption: "\(reviewedTodayCount) reviewed",
                systemImage: "checkmark.seal.fill",
                tone: .accentColor
            )

            MetricCard(
                title: "Focus Average",
                value: averageFocusText,
                caption: reviewedTodayCount > 0 ? "based on submitted reviews" : "review a block to score it",
                systemImage: "scope",
                tone: .accentColor
            )

            MetricCard(
                title: "Adherence Avg",
                value: adherenceAverageText,
                caption: reviewedTodayCount > 0 ? "0 to 10, from submitted reviews" : "waiting for review data",
                systemImage: "flag.pattern.checkered",
                tone: .orange
            )
        }
    }

    private var spotlightRow: some View {
        HStack(alignment: .top, spacing: 18) {
            DashboardPanel {
                HStack(alignment: .top, spacing: 14) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Live Session")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)

                        if let session = model.deviceState?.activeSession {
                            Text(session.displayTitle)
                                .font(.system(size: 28, weight: .bold, design: .rounded))
                                .lineLimit(2)

                            Text(sessionWindow(startTimeMs: session.startTimeMs, stopTimeMs: session.stopTimeMs))
                                .foregroundStyle(.secondary)

                            Text(durationText(effectiveDurationMs(for: session)))
                                .font(.system(size: 36, weight: .black, design: .rounded))
                                .monospacedDigit()

                            HStack(spacing: 10) {
                                StatusBadge(
                                    title: focusStateTitle(for: session.focusStatus),
                                    tone: session.focusStatus == "started" ? .green : .yellow
                                )
                                StatusBadge(title: "Toggl live", tone: .accentColor)
                            }

                            if !session.tags.isEmpty {
                                Text(session.tags.joined(separator: " · "))
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            Text("No live session")
                                .font(.system(size: 26, weight: .bold, design: .rounded))
                            Text("Start a Toggl timer and the dashboard will flip into live tracking automatically.")
                                .foregroundStyle(.secondary)
                            if let recent = recentSessions.first {
                                Text("Last block: \(recent.displayTitle)")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    Spacer(minLength: 0)
                }
            }

            DashboardPanel {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Review Queue")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)

                    if let pendingReview = model.deviceState?.pendingReview {
                        Text(pendingReview.displayTitle)
                            .font(.system(size: 26, weight: .bold, design: .rounded))
                            .lineLimit(2)

                        Text(sessionWindow(startTimeMs: pendingReview.startTimeMs, stopTimeMs: pendingReview.stopTimeMs))
                            .foregroundStyle(.secondary)

                        if let existingReview = pendingReview.existingReview,
                           !existingReview.whatWentWell.isEmpty || !existingReview.whatDidntGoWell.isEmpty {
                            Text(existingReview.whatWentWell.isEmpty ? existingReview.whatDidntGoWell : existingReview.whatWentWell)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Capture the score and set the next block while the details are fresh.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }

                        HStack(spacing: 12) {
                            Button("Open review") {
                                model.openPendingReview()
                            }
                            .buttonStyle(.borderedProminent)

                            Button("Reconnect live sync") {
                                Task {
                                    await model.pollOnce()
                                    await model.refreshDashboardNow()
                                }
                            }
                            .buttonStyle(.bordered)
                        }
                    } else {
                        Text("Inbox clear")
                            .font(.system(size: 24, weight: .bold, design: .rounded))
                        Text("No review is waiting right now. Keep the cadence tight and this board becomes your work memory.")
                            .foregroundStyle(.secondary)

                        HStack(spacing: 12) {
                            Button("Reconnect live sync") {
                                Task {
                                    await model.pollOnce()
                                    await model.refreshDashboardNow()
                                }
                            }
                            .buttonStyle(.borderedProminent)

                            Button("Open settings") {
                                selection = .settings
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
            }
        }
    }

    private var recentSessionsSection: some View {
        DashboardPanel {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Recent Sessions")
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                    Text("The last blocks, with review signal stitched in.")
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text("\(recentSessions.count) loaded")
                    .font(.footnote.monospaced())
                    .foregroundStyle(.secondary)
            }

            if recentSessions.isEmpty {
                Text("No sessions yet. Once Toggl starts flowing, this feed becomes your operational history.")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 12) {
                    ForEach(recentSessions.prefix(8)) { session in
                        SessionRowView(session: session)
                    }
                }
            }
        }
    }

    private var backendPulseSection: some View {
        DashboardPanel {
            Text("System Pulse")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                PulseCell(
                    label: "Last live update",
                    value: model.lastSuccessfulPollAt.map {
                        Self.relativeFormatter.localizedString(for: $0, relativeTo: Date())
                    } ?? "Never",
                    tone: .accentColor
                )

                PulseCell(
                    label: "Last webhook",
                    value: model.deviceState?.integration.lastWebhookAt.map { relativeText(from: $0) } ?? "No event",
                    tone: .green
                )

                PulseCell(
                    label: "Workspace",
                    value: model.deviceState?.integration.togglWorkspaceId.map(String.init) ?? "Missing",
                    tone: .purple
                )
            }

            if let lastError = model.lastError, !lastError.isEmpty {
                Text(lastError)
                    .font(.footnote)
                    .foregroundStyle(.red)
            } else if let lastNotice = model.lastNotice, !lastNotice.isEmpty {
                Text(lastNotice)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var settingsView: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Settings")
                    .font(.system(size: 34, weight: .black, design: .rounded))
                Text("Pairing, shortcut wiring, and recovery tools live here. The dashboard stays focused on the work itself.")
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 28)
            .padding(.top, 26)
            .padding(.bottom, 12)

            Form {
                connectionSection
                automationSection
                dailyReportSection
                aiSection
                deviceSection
                backendSection
                toolsSection
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .padding(.horizontal, 12)
            .padding(.bottom, 16)
        }
    }

    private var connectionSection: some View {
        Section("Pairing") {
            TextField("Backend base URL", text: configBinding(\.backendBaseURL))
            SecureField("Setup key", text: configBinding(\.setupKey))

            Text("Use the Convex HTTP actions host ending in .convex.site. The app will normalize pasted .convex.cloud URLs automatically.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            HStack {
                Button(model.hasCompletedSetup ? "Re-run setup" : "Pair device") {
                    Task {
                        await model.bootstrap()
                    }
                }
                .disabled(
                    model.isBootstrapping ||
                    model.configuration.backendBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                    model.configuration.setupKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )

                if model.hasCompletedSetup {
                    Button("Reset pairing", role: .destructive) {
                        model.resetPairing()
                    }
                }

                if model.isBootstrapping {
                    ProgressView()
                        .controlSize(.small)
                }
            }
        }
    }

    private var automationSection: some View {
        Section("Automation") {
            TextField("Device name", text: configBinding(\.deviceName))
            TextField("Bundle ID", text: configBinding(\.bundleID))

            Toggle("Auto-start Raycast Focus", isOn: configBinding(\.autoStartFocus))
            Toggle("Auto-complete Raycast Focus", isOn: configBinding(\.autoCompleteFocus))
            Toggle("Auto-show review popup", isOn: configBinding(\.autoShowReview))

            TextField("Start shortcut name", text: configBinding(\.startShortcutName))
            TextField("Complete shortcut name", text: configBinding(\.completeShortcutName))
        }
    }

    private var aiSection: some View {
        Section("AI Assist") {
            SecureField("OpenAI API key", text: openAIAPIKeyBinding)

            LabeledContent("Status") {
                Text(model.isAIConfigured ? "Configured" : "Not configured")
                    .foregroundStyle(model.isAIConfigured ? .primary : .secondary)
            }

            Text("Optional. AI can extract review fields from freeform notes and write higher-signal daily reports. Nothing is auto-submitted.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var dailyReportSection: some View {
        Section("Daily report") {
            Toggle("Generate end-of-day report", isOn: configBinding(\.dailyReportEnabled))

            DatePicker(
                "Report time",
                selection: dailyReportTimeBinding,
                displayedComponents: [.hourAndMinute]
            )
            .disabled(!model.configuration.dailyReportEnabled)

            Toggle(
                "Notify when report is ready",
                isOn: configBinding(\.notifyWhenDailyReportReady)
            )
            .disabled(!model.configuration.dailyReportEnabled)

            Text("The report covers the 24-hour window ending at this time. Set it late, like 2:00 AM, if your day usually runs past midnight.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var deviceSection: some View {
        Section("Device") {
            LabeledContent("Status") {
                Text(model.connectionStatus)
            }

            LabeledContent("Device ID") {
                Text(model.configuration.deviceId.isEmpty ? "Not paired" : model.configuration.deviceId)
                    .textSelection(.enabled)
                    .font(.footnote.monospaced())
            }

            LabeledContent("Pending reviews") {
                Text("\(model.pendingReviewsCount)")
            }

            if let lastSeenAt = model.deviceState?.device.lastSeenAt {
                LabeledContent("Last presence sync") {
                    Text(Self.dateFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(lastSeenAt) / 1000)))
                }
            }
        }
    }

    private var backendSection: some View {
        Section("Backend") {
            LabeledContent("Toggl workspace") {
                if let workspaceID = model.deviceState?.integration.togglWorkspaceId {
                    Text(String(workspaceID))
                } else {
                    Text("Not configured")
                }
            }

            LabeledContent("Webhook") {
                Text(model.deviceState?.integration.togglWebhookUrl ?? "Not configured")
                    .textSelection(.enabled)
                    .font(.footnote)
            }

            if let validatedAt = model.deviceState?.integration.togglWebhookValidatedAt {
                LabeledContent("Webhook validated") {
                    Text(Self.dateFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(validatedAt) / 1000)))
                }
            }

            if let lastWebhookAt = model.deviceState?.integration.lastWebhookAt {
                LabeledContent("Last webhook event") {
                    Text(Self.dateFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(lastWebhookAt) / 1000)))
                }
            }

            if let lastAction = model.deviceState?.integration.lastWebhookAction,
               let entryID = model.deviceState?.integration.lastWebhookTimeEntryId {
                LabeledContent("Last Toggl event") {
                    Text("\(lastAction) / \(entryID)")
                }
            }

            if let lastSuccessfulPollAt = model.lastSuccessfulPollAt {
                LabeledContent("Last live update") {
                    Text(Self.dateFormatter.string(from: lastSuccessfulPollAt))
                }
            }

            if let lastNotice = model.lastNotice, !lastNotice.isEmpty {
                Text(lastNotice)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if let lastError = model.lastError, !lastError.isEmpty {
                Text(lastError)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
    }

    private var toolsSection: some View {
        Section("Tools") {
            HStack {
                Button("Pull Toggl") {
                    Task {
                        await model.pullNow()
                    }
                }
                .disabled(model.isPulling || !model.configuration.isPaired)

                if model.isPulling {
                    ProgressView()
                        .controlSize(.small)
                }

                Button("Reconnect live sync") {
                    Task {
                        await model.pollOnce()
                        await model.refreshDashboardNow()
                    }
                }
                .disabled(model.isPulling || !model.configuration.isPaired)

                Button("Generate report") {
                    Task {
                        await model.generateLatestCompletedDailyReport()
                    }
                }
                .disabled(model.isGeneratingDailyReport || !model.configuration.isPaired)

                if model.deviceState?.pendingReview != nil {
                    Button("Open review") {
                        model.openPendingReview()
                    }
                }
            }

            Text("`Pull Toggl` is a manual recovery path. Day-to-day detection should come from the Toggl webhook and the live Convex subscription.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var sidebarFooter: some View {
        DashboardPanel(cornerRadius: 20, padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Today")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Text(durationText(trackedTodayMs))
                    .font(.system(size: 28, weight: .black, design: .rounded))
                    .monospacedDigit()

                Text("\(completedTodayCount) complete · \(model.pendingReviewsCount) waiting")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var dashboardHeadline: String {
        if let activeSession = model.deviceState?.activeSession {
            return "Working on \(activeSession.displayTitle.lowercased())."
        }

        if model.pendingReviewsCount > 0 {
            return "Close the loop on the last block before you start the next one."
        }

        if todaySessions.isEmpty {
            return "No sessions logged today yet. Start a timer and turn this into a work ledger."
        }

        return "The system has a record. Use it to tighten the next block."
    }

    private var webhookBadgeTitle: String {
        if let lastWebhookAt = model.deviceState?.integration.lastWebhookAt,
           Date().timeIntervalSince1970 - (TimeInterval(lastWebhookAt) / 1000) < 300 {
            return "Webhook live"
        }

        if model.deviceState?.integration.togglWebhookValidatedAt != nil {
            return "Webhook ready"
        }

        return "Webhook cold"
    }

    private var webhookBadgeTone: Color {
        if let lastWebhookAt = model.deviceState?.integration.lastWebhookAt,
           Date().timeIntervalSince1970 - (TimeInterval(lastWebhookAt) / 1000) < 300 {
            return .green
        }

        return model.deviceState?.integration.togglWebhookValidatedAt != nil ? .yellow : .red
    }

    private var latestReflectionNote: String? {
        recentSessions
            .compactMap { session in
                let wentWell = session.existingReview?.whatWentWell.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let didntGoWell = session.existingReview?.whatDidntGoWell.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return !wentWell.isEmpty ? wentWell : (!didntGoWell.isEmpty ? didntGoWell : nil)
            }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
    }

    private var recentSessions: [IntentDashboardSession] {
        model.dashboardState?.recentSessions ?? []
    }

    private var todaySessions: [IntentDashboardSession] {
        recentSessions.filter { session in
            Calendar.current.isDate(
                Date(timeIntervalSince1970: TimeInterval(session.startTimeMs) / 1000),
                inSameDayAs: Date()
            )
        }
    }

    private var trackedTodayMs: Int {
        todaySessions.reduce(0) { partialResult, session in
            partialResult + effectiveDurationMs(for: session)
        }
    }

    private var trackingStreak: IntentTrackingStreak {
        IntentTrackingStreak.compute(
            from: model.metricsState?.dailyDurationSeries ?? [],
            windowDays: model.metricsWindowDays
        )
    }

    private var completedTodayCount: Int {
        todaySessions.filter { $0.status == "completed" }.count
    }

    private var reviewedTodayCount: Int {
        todaySessions.filter { $0.existingReview != nil }.count
    }

    private var averageFocusText: String {
        let scores = todaySessions.compactMap { $0.existingReview?.numericMetric("focus") }
        guard !scores.isEmpty else {
            return "—"
        }

        let average = Double(scores.reduce(0, +)) / Double(scores.count)
        return String(format: "%.1f", average)
    }

    private var adherenceAverageText: String {
        let scores = todaySessions.compactMap { $0.existingReview?.numericMetric("adherence") }
        guard !scores.isEmpty else {
            return "—"
        }

        let average = Double(scores.reduce(0, +)) / Double(scores.count)
        return String(format: "%.1f", average)
    }

    private var topCategory: String? {
        let category = todaySessions
            .compactMap(\.existingReview?.taskCategory)
            .reduce(into: [String: Int]()) { partialResult, value in
                partialResult[value, default: 0] += 1
            }
            .max { left, right in
                left.value < right.value
            }?
            .key

        return category
    }

    private var projectNameSuggestions: [String] {
        var counts = [String: Int]()
        for session in recentSessions {
            let name = session.projectName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if name.isEmpty {
                continue
            }
            counts[name, default: 0] += 1
        }

        return counts
            .sorted { left, right in
                if left.value == right.value {
                    return left.key < right.key
                }
                return left.value > right.value
            }
            .map(\.key)
    }

    private var taskCategorySuggestions: [String] {
        var counts = [String: Int]()
        for session in recentSessions {
            let category = session.existingReview?.taskCategory.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if category.isEmpty {
                continue
            }
            counts[category, default: 0] += 1
        }

        return counts
            .sorted { left, right in
                if left.value == right.value {
                    return left.key < right.key
                }
                return left.value > right.value
            }
            .map(\.key)
    }

    private var dashboardBackdrop: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)

            Circle()
                .fill(Color.accentColor.opacity(0.14))
                .frame(width: 420, height: 420)
                .blur(radius: 70)
                .offset(x: -320, y: -240)

            Circle()
                .fill(Color.orange.opacity(0.10))
                .frame(width: 360, height: 360)
                .blur(radius: 90)
                .offset(x: 380, y: -160)

            LinearGradient(
                colors: [
                    Color.primary.opacity(0.02),
                    Color.clear,
                    Color.primary.opacity(0.04),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .ignoresSafeArea()
    }

    private func configBinding<Value>(_ keyPath: WritableKeyPath<IntentLocalConfiguration, Value>) -> Binding<Value> {
        Binding(
            get: {
                model.configuration[keyPath: keyPath]
            },
            set: { newValue in
                model.updateConfiguration { configuration in
                    configuration[keyPath: keyPath] = newValue
                }
            }
        )
    }

    private var openAIAPIKeyBinding: Binding<String> {
        Binding(
            get: {
                model.openAIAPIKey
            },
            set: { newValue in
                model.setOpenAIAPIKey(newValue)
            }
        )
    }

    private var dailyReportTimeBinding: Binding<Date> {
        Binding(
            get: {
                let dayStart = Calendar.current.startOfDay(for: Date())
                return Calendar.current.date(
                    byAdding: .minute,
                    value: model.configuration.dailyReportTimeMinutes,
                    to: dayStart
                ) ?? dayStart
            },
            set: { newValue in
                let components = Calendar.current.dateComponents([.hour, .minute], from: newValue)
                let totalMinutes = (components.hour ?? 0) * 60 + (components.minute ?? 0)
                model.updateConfiguration { configuration in
                    configuration.dailyReportTimeMinutes = max(0, min(totalMinutes, 1_439))
                }
            }
        )
    }

    private var activeReviewBinding: Binding<IntentReviewContext>? {
        guard model.activeReview != nil else {
            return nil
        }

        return Binding(
            get: {
                model.activeReview ?? IntentReviewContext(
                    session: IntentPendingReview(
                        id: "",
                        source: "toggl",
                        sourceTimeEntryId: "",
                        workspaceId: 0,
                        togglUserId: nil,
                        togglProjectId: nil,
                        projectName: nil,
                        togglTaskId: nil,
                        description: "",
                        tags: [],
                        billable: nil,
                        startTimeMs: 0,
                        stopTimeMs: nil,
                        durationMs: nil,
                        status: "completed",
                        focusStatus: "completed",
                        reviewStatus: "pending",
                        sourceUpdatedAt: 0,
                        createdAt: 0,
                        updatedAt: 0,
                        existingReview: nil
                    ),
                    draft: IntentReviewDraft(existingReview: nil)
                )
            },
            set: { newValue in
                model.activeReview = newValue
            }
        )
    }

    private func effectiveDurationMs(for session: IntentSessionSummary) -> Int {
        if let durationMs = session.durationMs {
            return durationMs
        }

        let stopMs = session.stopTimeMs ?? Int(Date().timeIntervalSince1970 * 1000)
        return max(0, stopMs - session.startTimeMs)
    }

    private func effectiveDurationMs(for session: IntentDashboardSession) -> Int {
        if let durationMs = session.durationMs {
            return durationMs
        }

        let stopMs = session.stopTimeMs ?? Int(Date().timeIntervalSince1970 * 1000)
        return max(0, stopMs - session.startTimeMs)
    }

    private func sessionWindow(startTimeMs: Int, stopTimeMs: Int?) -> String {
        let start = Date(timeIntervalSince1970: TimeInterval(startTimeMs) / 1000)
        let stop = stopTimeMs.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) }
        let startText = Self.shortTimeFormatter.string(from: start)
        let stopText = stop.map { Self.shortTimeFormatter.string(from: $0) } ?? "Running"
        return "\(startText) - \(stopText)"
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

    private func focusStateTitle(for focusStatus: String) -> String {
        switch focusStatus {
        case "started":
            return "Focus started"
        case "completed":
            return "Focus closed"
        case "pending":
            return "Focus pending"
        default:
            return "Focus idle"
        }
    }

    private func relativeText(from milliseconds: Int) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1000)
        return Self.relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter
    }()

    private static let shortTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter
    }()

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()
}

private struct DashboardPanel<Content: View>: View {
    let cornerRadius: CGFloat
    let padding: CGFloat
    let content: Content

    init(
        cornerRadius: CGFloat = 26,
        padding: CGFloat = 22,
        @ViewBuilder content: () -> Content
    ) {
        self.cornerRadius = cornerRadius
        self.padding = padding
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            content
        }
        .padding(padding)
        .background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                )
        )
    }
}

private struct StatusBadge: View {
    let title: String
    let tone: Color

    var body: some View {
        Text(title)
            .font(.system(size: 12, weight: .bold, design: .rounded))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous)
                    .fill(tone.opacity(0.14))
                    .overlay(
                        Capsule(style: .continuous)
                            .strokeBorder(tone.opacity(0.28), lineWidth: 1)
                    )
            )
            .foregroundStyle(tone)
    }
}

private struct MetricCard: View {
    let title: String
    let value: String
    let caption: String
    let systemImage: String
    let tone: Color

    var body: some View {
        DashboardPanel(cornerRadius: 24, padding: 18) {
            HStack {
                Image(systemName: systemImage)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(tone)
                Spacer()
            }

            Text(title)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)

            Text(value)
                .font(.system(size: 34, weight: .black, design: .rounded))
                .monospacedDigit()

            Text(caption)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

private struct PulseCell: View {
    let label: String
    let value: String
    let tone: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label.uppercased())
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)

            Text(value)
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundStyle(tone)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(tone.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(tone.opacity(0.18), lineWidth: 1)
                )
        )
    }
}

private struct SessionRowView: View {
    let session: IntentDashboardSession

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    Text(session.displayTitle)
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .lineLimit(1)

                    StatusBadge(title: session.status.capitalized, tone: session.status == "running" ? .green : .gray)
                }

                Text(sessionWindow)
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                if let review = session.existingReview {
                    let focus = review.numericMetric("focus")
                    let adherence = review.numericMetric("adherence")

                    HStack(spacing: 10) {
                        if let focus {
                            Text("Focus \(focus)/10")
                        }
                        if let adherence {
                            Text("Adherence \(adherence)/10")
                        }
                        Text(review.taskCategory.capitalized)
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                    if !review.whatWentWell.isEmpty || !review.whatDidntGoWell.isEmpty {
                        Text(review.whatWentWell.isEmpty ? review.whatDidntGoWell : review.whatWentWell)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                } else {
                    Text(session.reviewStatus == "pending" ? "Review still waiting." : "No review saved.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 8) {
                Text(durationText)
                    .font(.system(size: 20, weight: .black, design: .rounded))
                    .monospacedDigit()

                if !session.tags.isEmpty {
                    Text(session.tags.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }
            }
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.primary.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
                )
        )
    }

    private var sessionWindow: String {
        let start = Date(timeIntervalSince1970: TimeInterval(session.startTimeMs) / 1000)
        let stop = session.stopTimeMs.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) }
        let startText = Self.shortTimeFormatter.string(from: start)
        let stopText = stop.map { Self.shortTimeFormatter.string(from: $0) } ?? "Running"
        return "\(startText) - \(stopText)"
    }

    private var durationText: String {
        let durationMs: Int
        if let explicitDuration = session.durationMs {
            durationMs = explicitDuration
        } else {
            let stopMs = session.stopTimeMs ?? Int(Date().timeIntervalSince1970 * 1000)
            durationMs = max(0, stopMs - session.startTimeMs)
        }

        let totalMinutes = max(0, durationMs / 60_000)
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }

    private static let shortTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter
    }()
}
