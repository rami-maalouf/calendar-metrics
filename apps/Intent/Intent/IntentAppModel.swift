//
//  IntentAppModel.swift
//  Intent
//
//  Created by Codex on 2026-03-10.
//

import AppKit
import Combine
import ConvexMobile
import Foundation
import UserNotifications
import WidgetKit

@MainActor
final class IntentAppModel: ObservableObject {
    @Published var configuration: IntentLocalConfiguration {
        didSet {
            configuration.persist()
        }
    }

    @Published var deviceState: IntentDeviceState?
    @Published var dashboardState: IntentDashboardState?
    @Published var metricsState: IntentMetricsState?
    @Published var intentionalityState: IntentIntentionalityState?
    @Published var screenDay: IntentScreenDay?
    @Published var screenDays: [IntentScreenDay] = []
    @Published var activeReview: IntentReviewContext?
    @Published var isBootstrapping = false
    @Published var isSubmittingReview = false
    @Published var isPulling = false
    @Published var openAIAPIKey: String
    @Published var connectionStatus = "Needs setup"
    @Published var lastError: String?
    @Published var lastNotice: String?
    @Published var lastSuccessfulPollAt: Date?
    @Published var metricsWindowDays = 21
    @Published var dailyReports: [IntentGeneratedDailyReport]
    @Published var isGeneratingDailyReport = false

    private var convexClient: ConvexClient?
    private var convexDeploymentURL: String?
    private var operationalStateSubscription: AnyCancellable?
    private var webSocketStateSubscription: AnyCancellable?
    private var settingsSyncTask: Task<Void, Never>?
    private var dailyReportTask: Task<Void, Never>?
    private var intentionalityTask: Task<Void, Never>?
    private var isPullInFlight = false
    private var isDashboardRefreshInFlight = false
    private var startFocusInFlight = Set<String>()
    private var completeFocusInFlight = Set<String>()
    private var presentedReviewInFlight = Set<String>()
    private var acknowledgedPresentedReviews = Set<String>()
    private var startFocusRetryAfter = [String: Date]()
    private var completeFocusRetryAfter = [String: Date]()
    private var knownShortcutNames = Set<String>()
    private var lastShortcutRefreshAt: Date?
    private var lastDashboardRefreshAt: Date?
    private var unavailableShortcuts = Set<String>()
    private var lastObservedWebSocketState: WebSocketState?

    private let settingsSyncDebounceSeconds: TimeInterval = 0.8
    private let shortcutRefreshIntervalSeconds: TimeInterval = 60
    private let dailyReportCheckIntervalSeconds: TimeInterval = 60
    private let dashboardRefreshDebounceSeconds: TimeInterval = 15
    private let dailyReportStore: IntentDailyReportStore

    init() {
        let configuration = IntentLocalConfiguration.load()
        self.configuration = configuration
        self.openAIAPIKey = IntentSecretStore.openAIAPIKey() ?? ""
        self.dailyReportStore = .shared
        self.dailyReports = IntentDailyReportStore.shared.load()
        if configuration.isPaired {
            connectionStatus = "Ready"
            // begin polling immediately: the app can launch straight to the
            // menu bar with no window, so view-level .task hooks never fire
            Task { [weak self] in
                self?.start()
            }
        }
    }

    var hasCompletedSetup: Bool {
        configuration.isPaired
    }

    var currentSessionTitle: String {
        deviceState?.activeSession?.displayTitle ?? "No active session"
    }

    var pendingReviewsCount: Int {
        deviceState?.pendingReviewsCount ?? 0
    }

    var isAIConfigured: Bool {
        !openAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var latestDailyReport: IntentGeneratedDailyReport? {
        dailyReports.sorted { $0.intervalStartMs > $1.intervalStartMs }.first
    }

    func start() {
        guard configuration.isPaired else {
            return
        }

        ensureRealtimeConnection(forceReconnect: false)

        if dailyReportTask == nil {
            dailyReportTask = Task { [weak self] in
                guard let self else { return }
                await self.dailyReportLoop()
            }
        }

        if intentionalityTask == nil {
            intentionalityTask = Task { [weak self] in
                guard let self else { return }
                await self.intentionalityLoop()
            }
        }
    }

    func stop() {
        stopRealtimeConnection()
        settingsSyncTask?.cancel()
        settingsSyncTask = nil
        dailyReportTask?.cancel()
        dailyReportTask = nil
        intentionalityTask?.cancel()
        intentionalityTask = nil
    }

    func updateConfiguration(_ update: (inout IntentLocalConfiguration) -> Void) {
        let previous = configuration
        var next = configuration
        update(&next)
        configuration = next
        knownShortcutNames.removeAll()
        lastShortcutRefreshAt = nil
        unavailableShortcuts.removeAll()

        let realtimeIdentityChanged =
            previous.backendBaseURL != next.backendBaseURL ||
            previous.deviceId != next.deviceId ||
            previous.deviceSecret != next.deviceSecret
        let deviceSettingsChanged =
            previous.autoStartFocus != next.autoStartFocus ||
            previous.autoCompleteFocus != next.autoCompleteFocus ||
            previous.autoShowReview != next.autoShowReview ||
            previous.startShortcutName != next.startShortcutName ||
            previous.completeShortcutName != next.completeShortcutName ||
            previous.bundleID != next.bundleID

        if !next.isPaired {
            stopRealtimeConnection()
            return
        }

        if realtimeIdentityChanged {
            ensureRealtimeConnection(forceReconnect: true)
        } else {
            ensureRealtimeConnection(forceReconnect: false)
        }

        if deviceSettingsChanged {
            scheduleDeviceSettingsSync(recordPresence: false, immediate: false)
        }

        if dailyReportTask == nil {
            start()
        }
    }

    func bootstrap() async {
        guard !isBootstrapping else {
            return
        }

        isBootstrapping = true
        defer { isBootstrapping = false }

        do {
            let baseURL = try normalizedBackendBaseURL(from: configuration.backendBaseURL)
            if configuration.backendBaseURL != baseURL.absoluteString {
                updateConfiguration { configuration in
                    configuration.backendBaseURL = baseURL.absoluteString
                }
            }

            try await verifyBackend(baseURL: baseURL)

            let response: IntentBootstrapResponse = try await post(
                path: "/intent/bootstrap",
                body: IntentBootstrapRequest(
                    setupKey: configuration.setupKey,
                    deviceName: configuration.deviceName,
                    platform: "macos",
                    settings: deviceSettingsPayload
                )
            )

            updateConfiguration { configuration in
                configuration.deviceId = response.device.deviceId
                configuration.deviceSecret = response.device.deviceSecret
            }

            lastError = response.webhook.reason
            lastNotice = nil
            connectionStatus = response.webhook.configured ? "Connecting" : "Paired"
            start()
            await syncDeviceSettingsNow(recordPresence: true, showErrors: false)
            await refreshDashboardOnce()
        } catch {
            lastNotice = nil
            lastError = displayMessage(for: error)
            connectionStatus = "Setup failed"
        }
    }

    func pollOnce() async {
        guard configuration.isPaired else {
            connectionStatus = "Needs setup"
            return
        }

        ensureRealtimeConnection(forceReconnect: true)
        await syncDeviceSettingsNow(recordPresence: true, showErrors: true)
    }

    func pullNow() async {
        guard configuration.isPaired else {
            return
        }

        do {
            _ = try await performPull(showNotice: true)
            await refreshDashboardOnce()
        } catch {
            lastNotice = nil
            lastError = displayMessage(for: error)
        }
    }

    func submitActiveReview() async {
        guard let activeReview, !isSubmittingReview else {
            return
        }

        isSubmittingReview = true
        defer { isSubmittingReview = false }

        do {
            let draft = activeReview.draft
            guard draft.hasMeaningfulContent else {
                return
            }
            let _: IntentOKResponse = try await post(
                path: "/intent/device/review/submit",
                body: IntentSubmitReviewRequest(
                    deviceId: configuration.deviceId,
                    deviceSecret: configuration.deviceSecret,
                    sessionId: activeReview.session.id,
                    numericMetrics: draft.numericMetrics,
                    countMetrics: draft.countMetrics,
                    booleanMetrics: draft.booleanMetrics,
                    taskCategory: draft.taskCategory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : draft.taskCategory,
                    projectName: draft.projectName.isEmpty ? nil : draft.projectName,
                    whatWentWell: draft.whatWentWell.isEmpty ? nil : draft.whatWentWell,
                    whatDidntGoWell: draft.whatDidntGoWell.isEmpty ? nil : draft.whatDidntGoWell
                )
            )

            acknowledgedPresentedReviews.insert(activeReview.session.id)
            self.activeReview = nil
            await refreshDashboardOnce()
            await refreshMetricsOnce()
        } catch {
            lastNotice = nil
            lastError = displayMessage(for: error)
        }
    }

    func dismissReview() {
        activeReview = nil
    }

    func openPendingReview() {
        guard let pendingReview = deviceState?.pendingReview else {
            return
        }

        activeReview = IntentReviewContext(
            session: pendingReview,
            draft: IntentReviewDraft(
                existingReview: pendingReview.existingReview,
                sessionProjectName: pendingReview.projectName
            )
        )
        bringAppToFront()
    }

    func resetPairing() {
        stop()
        deviceState = nil
        dashboardState = nil
        metricsState = nil
        activeReview = nil
        startFocusInFlight.removeAll()
        completeFocusInFlight.removeAll()
        presentedReviewInFlight.removeAll()
        acknowledgedPresentedReviews.removeAll()
        startFocusRetryAfter.removeAll()
        completeFocusRetryAfter.removeAll()
        knownShortcutNames.removeAll()
        lastShortcutRefreshAt = nil
        lastDashboardRefreshAt = nil
        unavailableShortcuts.removeAll()

        updateConfiguration { configuration in
            configuration.deviceId = ""
            configuration.deviceSecret = ""
        }

        connectionStatus = "Needs setup"
        lastError = nil
        lastNotice = nil
    }

    func refreshMetricsNow() async {
        do {
            try await loadMetrics(showErrors: true)
            try await loadIntentionality(showErrors: true)
        } catch {
            lastNotice = nil
            lastError = displayMessage(for: error)
        }
    }

    func refreshIntentionalityNow() async {
        do {
            try await loadIntentionality(showErrors: true)
        } catch {
            lastNotice = nil
            lastError = displayMessage(for: error)
        }
    }

    func refreshDashboardNow() async {
        do {
            try await loadDashboard(showErrors: true)
        } catch {
            lastNotice = nil
            lastError = displayMessage(for: error)
        }
    }

    func setMetricsWindowDays(_ value: Int) {
        guard metricsWindowDays != value else {
            return
        }

        metricsWindowDays = value
        Task {
            await refreshMetricsNow()
        }
    }

    func setOpenAIAPIKey(_ value: String) {
        do {
            try IntentSecretStore.setOpenAIAPIKey(value)
            openAIAPIKey = value.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            lastNotice = nil
            lastError = displayMessage(for: error)
        }
    }

    func extractReviewDraft(
        from text: String,
        for session: IntentPendingReview,
        taskCategorySuggestions: [String]
    ) async throws -> IntentReviewAIPatch {
        try await IntentReviewExtractionService().extract(
            from: text,
            session: session,
            taskCategorySuggestions: taskCategorySuggestions
        )
    }

    func generateLatestCompletedDailyReport(force: Bool = true) async {
        guard configuration.isPaired else {
            return
        }

        let window = IntentDailyReportScheduler.mostRecentCompletedWindow(
            relativeTo: Date(),
            minutesAfterMidnight: configuration.dailyReportTimeMinutes
        )
        await generateDailyReport(
            for: window,
            force: force,
            notifyWhenReady: configuration.notifyWhenDailyReportReady
        )
    }

    private var deviceSettingsPayload: IntentDeviceSettingsPayload {
        IntentDeviceSettingsPayload(
            autoStartFocus: configuration.autoStartFocus,
            autoCompleteFocus: configuration.autoCompleteFocus,
            autoShowReview: configuration.autoShowReview,
            startShortcutName: configuration.startShortcutName,
            completeShortcutName: configuration.completeShortcutName,
            bundleId: configuration.bundleID
        )
    }

    private var deviceSettingsArguments: [String: ConvexEncodable?] {
        [
            "autoStartFocus": configuration.autoStartFocus,
            "autoCompleteFocus": configuration.autoCompleteFocus,
            "autoShowReview": configuration.autoShowReview,
            "startShortcutName": configuration.startShortcutName,
            "completeShortcutName": configuration.completeShortcutName,
            "bundleId": configuration.bundleID
        ]
    }

    private var realtimeSubscriptionArguments: [String: ConvexEncodable?] {
        [
            "deviceId": configuration.deviceId,
            "deviceSecret": configuration.deviceSecret
        ]
    }

    private func ensureRealtimeConnection(forceReconnect: Bool) {
        guard configuration.isPaired else {
            stopRealtimeConnection()
            connectionStatus = "Needs setup"
            return
        }

        do {
            let deploymentURL = try normalizedConvexDeploymentURLString(from: configuration.backendBaseURL)
            let needsReconnect =
                forceReconnect ||
                convexClient == nil ||
                convexDeploymentURL != deploymentURL

            guard needsReconnect else {
                return
            }

            stopRealtimeConnection()

            let client = ConvexClient(deploymentUrl: deploymentURL)
            convexClient = client
            convexDeploymentURL = deploymentURL
            connectionStatus = "Connecting"

            webSocketStateSubscription = client.watchWebSocketState()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] state in
                    guard let self else { return }
                    Task { @MainActor in
                        await self.handleWebSocketState(state)
                    }
                }

            operationalStateSubscription = client.subscribe(
                to: "intent:deviceOperationalStateJson",
                with: realtimeSubscriptionArguments,
                yielding: String.self
            )
            .receive(on: DispatchQueue.main)
            .sink(
                receiveCompletion: { [weak self] completion in
                    guard let self else { return }
                    Task { @MainActor in
                        self.handleRealtimeCompletion(completion)
                    }
                },
                receiveValue: { [weak self] stateJSON in
                    guard let self else { return }
                    Task { @MainActor in
                        await self.applyRealtimeStateJSON(stateJSON)
                    }
                }
            )
        } catch {
            stopRealtimeConnection()
            connectionStatus = "Disconnected"
            lastNotice = nil
            lastError = displayMessage(for: error)
        }
    }

    private func stopRealtimeConnection() {
        operationalStateSubscription?.cancel()
        operationalStateSubscription = nil
        webSocketStateSubscription?.cancel()
        webSocketStateSubscription = nil
        convexClient = nil
        convexDeploymentURL = nil
        lastObservedWebSocketState = nil
    }

    private func scheduleDeviceSettingsSync(recordPresence: Bool, immediate: Bool) {
        guard configuration.isPaired else {
            return
        }

        settingsSyncTask?.cancel()
        settingsSyncTask = Task { [weak self] in
            guard let self else { return }

            if !immediate {
                do {
                    try await Task.sleep(
                        nanoseconds: UInt64(settingsSyncDebounceSeconds * 1_000_000_000)
                    )
                } catch {
                    return
                }
            }

            await self.syncDeviceSettingsNow(recordPresence: recordPresence, showErrors: false)
        }
    }

    private func syncDeviceSettingsNow(recordPresence: Bool, showErrors: Bool) async {
        guard configuration.isPaired else {
            return
        }

        ensureRealtimeConnection(forceReconnect: false)

        guard let convexClient else {
            if showErrors {
                lastNotice = nil
                lastError = "Live sync client is not available."
            }
            return
        }

        do {
            let _: Bool = try await convexClient.mutation(
                "intent:syncDeviceSettings",
                with: [
                    "deviceId": configuration.deviceId,
                    "deviceSecret": configuration.deviceSecret,
                    "settings": deviceSettingsArguments,
                    "recordPresence": recordPresence
                ]
            )
        } catch {
            if showErrors {
                lastNotice = nil
                lastError = displayMessage(for: error)
            }
        }
    }

    private func handleWebSocketState(_ state: WebSocketState) async {
        defer {
            lastObservedWebSocketState = state
        }

        switch state {
        case .connected:
            connectionStatus = "Connected"
            if lastObservedWebSocketState != .connected {
                await syncDeviceSettingsNow(recordPresence: true, showErrors: false)
            }
        case .connecting:
            if configuration.isPaired {
                connectionStatus = "Connecting"
            }
        }
    }

    private func handleRealtimeCompletion(_ completion: Subscribers.Completion<ClientError>) {
        switch completion {
        case .finished:
            connectionStatus = configuration.isPaired ? "Connecting" : "Needs setup"
        case .failure(let error):
            connectionStatus = "Disconnected"
            lastNotice = nil
            lastError = displayMessage(for: error)
        }
    }

    private func applyRealtimeStateJSON(_ stateJSON: String) async {
        do {
            let data = Data(stateJSON.utf8)
            let nextState = try JSONDecoder().decode(IntentDeviceState.self, from: data)
            let previousState = deviceState
            deviceState = nextState
            lastSuccessfulPollAt = Date()

            if let lastWebhookError = nextState.integration.lastWebhookError,
               !lastWebhookError.isEmpty {
                lastError = lastWebhookError
            } else if lastError == nil || lastError?.contains("Toggl") == true {
                lastError = nil
            }

            await maybeRefreshDashboardForStateTransition(from: previousState, to: nextState)
            await handle(nextState)
        } catch {
            lastNotice = nil
            lastError = displayMessage(for: error)
        }
    }

    private func dailyReportLoop() async {
        await maybeGenerateScheduledDailyReport()

        while !Task.isCancelled {
            do {
                try await Task.sleep(
                    nanoseconds: UInt64(dailyReportCheckIntervalSeconds * 1_000_000_000)
                )
            } catch {
                return
            }

            await maybeGenerateScheduledDailyReport()
        }
    }

    private func handle(_ state: IntentDeviceState) async {
        if let session = state.pendingFocusComplete {
            await maybeCompleteFocus(for: session)
        }

        if let session = state.pendingFocusStart {
            await maybeStartFocus(for: session)
        }

        if let pendingReview = state.pendingReview {
            await maybePresentReview(pendingReview)
        }
    }

    private func maybeRefreshDashboardForStateTransition(
        from previousState: IntentDeviceState?,
        to currentState: IntentDeviceState
    ) async {
        guard dashboardState != nil else {
            return
        }

        guard dashboardRefreshSignature(for: previousState) != dashboardRefreshSignature(for: currentState) else {
            return
        }

        if let lastDashboardRefreshAt,
           Date().timeIntervalSince(lastDashboardRefreshAt) < dashboardRefreshDebounceSeconds {
            return
        }

        await refreshDashboardOnce()
    }

    private func dashboardRefreshSignature(for state: IntentDeviceState?) -> String {
        guard let state else {
            return "none"
        }

        return [
            state.activeSession?.id ?? "none",
            state.activeSession?.status ?? "none",
            state.pendingReview?.id ?? "none",
            "\(state.pendingReviewsCount)"
        ].joined(separator: "|")
    }

    private func maybeStartFocus(for session: IntentSessionSummary) async {
        guard startFocusInFlight.insert(session.id).inserted else {
            return
        }

        defer { startFocusInFlight.remove(session.id) }

        if let retryAfter = startFocusRetryAfter[session.id], retryAfter > Date() {
            return
        }
        startFocusRetryAfter.removeValue(forKey: session.id)

        guard configuration.autoStartFocus else {
            return
        }

        let shortcutName = configuration.startShortcutName.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            guard try await ensureShortcutExists(named: shortcutName) else {
                unavailableShortcuts.insert(shortcutName)
                lastNotice = nil
                lastError = "Shortcut \"\(shortcutName)\" was not found in Apple Shortcuts. Create it, change the configured name, or turn off Auto-start Raycast Focus."
                return
            }
        } catch {
            lastNotice = nil
            lastError = displayMessage(for: error)
            return
        }

        if unavailableShortcuts.contains(shortcutName) {
            return
        }

        do {
            try await runShortcut(named: configuration.startShortcutName)
            let _: IntentOKResponse = try await post(
                path: "/intent/device/focus/start",
                body: IntentSessionActionRequest(
                    deviceId: configuration.deviceId,
                    deviceSecret: configuration.deviceSecret,
                    sessionId: session.id
                )
            )
            startFocusRetryAfter.removeValue(forKey: session.id)
        } catch {
            startFocusRetryAfter[session.id] = Date().addingTimeInterval(30)
            if isMissingShortcutError(error) {
                unavailableShortcuts.insert(shortcutName)
            }
            lastNotice = nil
            lastError = displayMessage(for: error)
        }
    }

    private func maybeCompleteFocus(for session: IntentSessionSummary) async {
        guard completeFocusInFlight.insert(session.id).inserted else {
            return
        }

        defer { completeFocusInFlight.remove(session.id) }

        if let retryAfter = completeFocusRetryAfter[session.id], retryAfter > Date() {
            return
        }
        completeFocusRetryAfter.removeValue(forKey: session.id)

        guard configuration.autoCompleteFocus else {
            return
        }

        let shortcutName = configuration.completeShortcutName.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            guard try await ensureShortcutExists(named: shortcutName) else {
                unavailableShortcuts.insert(shortcutName)
                lastNotice = nil
                lastError = "Shortcut \"\(shortcutName)\" was not found in Apple Shortcuts. Create it, change the configured name, or turn off Auto-complete Raycast Focus."
                return
            }
        } catch {
            lastNotice = nil
            lastError = displayMessage(for: error)
            return
        }

        if unavailableShortcuts.contains(shortcutName) {
            return
        }

        do {
            try await runShortcut(named: configuration.completeShortcutName)
            let _: IntentOKResponse = try await post(
                path: "/intent/device/focus/complete",
                body: IntentSessionActionRequest(
                    deviceId: configuration.deviceId,
                    deviceSecret: configuration.deviceSecret,
                    sessionId: session.id
                )
            )
            completeFocusRetryAfter.removeValue(forKey: session.id)
        } catch {
            completeFocusRetryAfter[session.id] = Date().addingTimeInterval(30)
            if isMissingShortcutError(error) {
                unavailableShortcuts.insert(shortcutName)
            }
            lastNotice = nil
            lastError = displayMessage(for: error)
        }
    }

    private func maybePresentReview(_ review: IntentPendingReview) async {
        if activeReview?.id != review.id {
            activeReview = IntentReviewContext(
                session: review,
                draft: IntentReviewDraft(
                    existingReview: review.existingReview,
                    sessionProjectName: review.projectName
                )
            )
            bringAppToFront()
        }

        if review.reviewStatus != "pending" {
            acknowledgedPresentedReviews.insert(review.id)
            return
        }

        guard !acknowledgedPresentedReviews.contains(review.id) else {
            return
        }

        guard presentedReviewInFlight.insert(review.id).inserted else {
            return
        }

        defer { presentedReviewInFlight.remove(review.id) }

        do {
            let _: IntentOKResponse = try await post(
                path: "/intent/device/review/presented",
                body: IntentSessionActionRequest(
                    deviceId: configuration.deviceId,
                    deviceSecret: configuration.deviceSecret,
                    sessionId: review.id
                )
            )
            acknowledgedPresentedReviews.insert(review.id)
        } catch {
            lastNotice = nil
            lastError = displayMessage(for: error)
        }
    }

    private func bringAppToFront() {
        NSApplication.shared.unhide(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        let frontableWindow = NSApplication.shared.windows.first {
            $0.canBecomeKey && !$0.isMiniaturized
        }
        frontableWindow?.makeKeyAndOrderFront(nil)
    }

    private func normalizedBackendBaseURL(from rawValue: String) throws -> URL {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw URLError(.badURL)
        }

        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard var components = URLComponents(string: candidate), let host = components.host else {
            throw URLError(.badURL)
        }

        if host.hasSuffix(".convex.cloud") {
            let deploymentName = String(host.dropLast(".convex.cloud".count))
            components.host = "\(deploymentName).convex.site"
        }

        components.path = ""
        components.query = nil
        components.fragment = nil

        guard let normalizedURL = components.url else {
            throw URLError(.badURL)
        }

        return normalizedURL
    }

    private func normalizedConvexDeploymentURLString(from rawValue: String) throws -> String {
        let backendURL = try normalizedBackendBaseURL(from: rawValue)
        guard var components = URLComponents(url: backendURL, resolvingAgainstBaseURL: false),
              let host = components.host else {
            throw URLError(.badURL)
        }

        if host.hasSuffix(".convex.site") {
            let deploymentName = String(host.dropLast(".convex.site".count))
            components.host = "\(deploymentName).convex.cloud"
        }

        components.path = ""
        components.query = nil
        components.fragment = nil

        guard let deploymentURL = components.url else {
            throw URLError(.badURL)
        }

        return deploymentURL.absoluteString
    }

    private func url(for path: String) throws -> URL {
        let base = try normalizedBackendBaseURL(from: configuration.backendBaseURL)
        return URL(string: path, relativeTo: base)?.absoluteURL ?? base
    }

    private func verifyBackend(baseURL: URL) async throws {
        var request = URLRequest(url: URL(string: "/intent/health", relativeTo: baseURL)?.absoluteURL ?? baseURL)
        request.httpMethod = "GET"

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            try validate(response: response, data: data)
        } catch {
            throw errorForBackendReachability(error, baseURL: baseURL)
        }
    }

    private func post<RequestBody: Encodable, ResponseBody: Decodable>(
        path: String,
        body: RequestBody
    ) async throws -> ResponseBody {
        var request = URLRequest(url: try url(for: path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
        return try JSONDecoder().decode(ResponseBody.self, from: data)
    }

    private func errorForBackendReachability(_ error: Error, baseURL: URL) -> Error {
        let nsError = error as NSError

        if nsError.domain == "IntentAPI", nsError.code == 404 {
            return NSError(
                domain: "IntentSetup",
                code: 404,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Intent backend not found at \(baseURL.absoluteString). Use your Convex HTTP Actions URL ending in .convex.site."
                ]
            )
        }

        if let urlError = error as? URLError {
            switch urlError.code {
            case .cannotFindHost, .dnsLookupFailed:
                return NSError(
                    domain: "IntentSetup",
                    code: Int(urlError.errorCode),
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Could not resolve \(baseURL.host() ?? baseURL.absoluteString). Convex HTTP actions use the .convex.site host. If that host is already correct, this is a local DNS/network issue on the Mac."
                    ]
                )
            default:
                break
            }
        }

        return error
    }

    private func displayMessage(for error: Error) -> String {
        let nsError = error as NSError
        if !nsError.localizedDescription.isEmpty {
            return nsError.localizedDescription
        }

        return error.localizedDescription
    }

    private func isMissingShortcutError(_ error: Error) -> Bool {
        let message = displayMessage(for: error)
        return message.contains("was not found in Apple Shortcuts")
    }

    private func performPull(showNotice: Bool) async throws -> IntentPullResponse {
        guard !isPullInFlight else {
            return IntentPullResponse(
                ok: true,
                pulled: false,
                reason: showNotice ? "A Toggl sync is already in progress." : nil
            )
        }

        isPullInFlight = true
        if showNotice {
            isPulling = true
        }

        defer {
            isPullInFlight = false
            if showNotice {
                isPulling = false
            }
        }

        let response: IntentPullResponse = try await post(
            path: "/intent/device/pull",
            body: IntentDevicePollRequest(
                deviceId: configuration.deviceId,
                deviceSecret: configuration.deviceSecret,
                settings: deviceSettingsPayload
            )
        )

        if showNotice {
            lastNotice = response.reason
            lastError = nil
        }

        return response
    }

    func refreshMetricsOnce() async {
        do {
            try await loadMetrics(showErrors: false)
        } catch {
            if metricsState == nil {
                lastNotice = nil
                lastError = displayMessage(for: error)
            }
        }
        await refreshIntentionalityOnce()
        await refreshScreenOnce()
    }

    // keeps the widget fed even if the metrics/visuals tabs are never opened:
    // refresh right after start(), then every 30 minutes
    private func intentionalityLoop() async {
        await refreshIntentionalityOnce()
        await refreshScreenOnce()

        while !Task.isCancelled {
            do {
                try await Task.sleep(nanoseconds: UInt64(30 * 60) * 1_000_000_000)
            } catch {
                return
            }

            await refreshIntentionalityOnce()
            await refreshScreenOnce()
        }
    }

    private func refreshIntentionalityOnce() async {
        try? await loadIntentionality(showErrors: false)
        await publishTrackedHoursToWidgets()
    }

    private func refreshScreenOnce() async {
        guard configuration.isPaired else {
            screenDay = nil
            screenDays = []
            return
        }

        do {
            let recent: IntentScreenRecentResponse = try await post(
                path: "/intent/device/screen/recent",
                body: IntentScreenRecentRequest(
                    deviceId: configuration.deviceId,
                    deviceSecret: configuration.deviceSecret,
                    limit: max(21, metricsWindowDays)
                )
            )
            screenDays = recent.days.sorted { $0.dayKey < $1.dayKey }

            let preferredDayKey =
                screenDays.reversed().first(where: { $0.totalSeconds >= 30 * 60 })?.dayKey
                ?? screenDays.last?.dayKey

            let summary: IntentScreenSummaryResponse = try await post(
                path: "/intent/device/screen/summary",
                body: IntentScreenSummaryRequest(
                    deviceId: configuration.deviceId,
                    deviceSecret: configuration.deviceSecret,
                    dayKey: preferredDayKey,
                    includeHours: true
                )
            )
            screenDay = summary.day ?? screenDays.last
        } catch {
            IntentWidgetShared.debugLog("[screen] failed: \(error)")
        }
    }

    // dedicated 90-day fetch so the tracked-hours widget is independent of
    // the metrics tab window picker; compacted before publishing
    private func publishTrackedHoursToWidgets() async {
        guard configuration.isPaired else {
            return
        }

        do {
            let response: IntentDeviceMetricsEnvelope = try await post(
                path: "/intent/device/metrics",
                body: IntentDeviceMetricsRequest(
                    deviceId: configuration.deviceId,
                    deviceSecret: configuration.deviceSecret,
                    windowDays: 90,
                    timeZoneOffsetMinutes: TimeZone.current.secondsFromGMT() / 60
                )
            )

            let days = (response.state.dailyDurationSeries ?? []).map { point in
                IntentTrackedHoursSnapshot.Day(
                    dayStartMs: Double(point.dayStart),
                    durationMs: point.durationMs,
                    sessionCount: point.sessionCount
                )
            }
            let snapshot = IntentTrackedHoursSnapshot(
                days: days,
                generatedAt: Date().timeIntervalSince1970 * 1000,
                windowDays: 90
            )

            guard IntentWidgetShared.saveTrackedHours(snapshot) else {
                IntentWidgetShared.debugLog("[trackedHours] publish failed: could not write app group defaults")
                return
            }

            WidgetCenter.shared.reloadAllTimelines()
        } catch {
            IntentWidgetShared.debugLog("[trackedHours] failed: \(error)")
        }
    }

    private func refreshDashboardOnce() async {
        do {
            try await loadDashboard(showErrors: false)
        } catch {
            if dashboardState == nil {
                lastNotice = nil
                lastError = displayMessage(for: error)
            }
        }
    }

    private func loadDashboard(showErrors: Bool) async throws {
        guard configuration.isPaired else {
            dashboardState = nil
            return
        }

        guard !isDashboardRefreshInFlight else {
            return
        }

        isDashboardRefreshInFlight = true
        defer { isDashboardRefreshInFlight = false }

        do {
            let response: IntentDeviceDashboardEnvelope = try await post(
                path: "/intent/device/dashboard",
                body: IntentDevicePollRequest(
                    deviceId: configuration.deviceId,
                    deviceSecret: configuration.deviceSecret,
                    settings: deviceSettingsPayload
                )
            )

            dashboardState = response.state
            lastDashboardRefreshAt = Date()
        } catch {
            if showErrors {
                throw error
            }
        }
    }

    private func loadMetrics(showErrors: Bool) async throws {
        guard configuration.isPaired else {
            metricsState = nil
            return
        }

        do {
            let response: IntentDeviceMetricsEnvelope = try await post(
                path: "/intent/device/metrics",
                body: IntentDeviceMetricsRequest(
                    deviceId: configuration.deviceId,
                    deviceSecret: configuration.deviceSecret,
                    windowDays: metricsWindowDays,
                    timeZoneOffsetMinutes: TimeZone.current.secondsFromGMT() / 60
                )
            )

            metricsState = response.state
        } catch {
            if showErrors {
                throw error
            }
        }
    }

    private func loadIntentionality(showErrors: Bool) async throws {
        guard configuration.isPaired else {
            intentionalityState = nil
            return
        }

        do {
            let response: IntentIntentionalityEnvelope = try await post(
                path: "/intent/device/intentionality",
                body: IntentDeviceIntentionalityRequest(
                    deviceId: configuration.deviceId,
                    deviceSecret: configuration.deviceSecret,
                    // 180 days so the trend widget can show 90 days plus a
                    // prior-90-day comparison window
                    windowDays: max(metricsWindowDays, 180),
                    timeZoneOffsetMinutes: TimeZone.current.secondsFromGMT() / 60
                )
            )

            intentionalityState = response.state
            publishIntentionalitySnapshotToWidgets(response.state)
        } catch {
            IntentWidgetShared.debugLog("[intentionality] failed: \(error)")
            if showErrors {
                throw error
            }
        }
    }

    private func publishIntentionalitySnapshotToWidgets(_ state: IntentIntentionalityState) {
        guard IntentWidgetShared.saveSnapshot(state) else {
            IntentWidgetShared.debugLog("[intentionality] publish failed: could not write app group defaults")
            return
        }

        WidgetCenter.shared.reloadAllTimelines()
    }

    private func maybeGenerateScheduledDailyReport() async {
        guard configuration.isPaired, configuration.dailyReportEnabled else {
            return
        }

        let window = IntentDailyReportScheduler.mostRecentCompletedWindow(
            relativeTo: Date(),
            minutesAfterMidnight: configuration.dailyReportTimeMinutes
        )
        await generateDailyReport(
            for: window,
            force: false,
            notifyWhenReady: configuration.notifyWhenDailyReportReady
        )
    }

    private func generateDailyReport(
        for window: IntentDailyReportWindow,
        force: Bool,
        notifyWhenReady: Bool
    ) async {
        guard configuration.isPaired else {
            return
        }

        if !force && dailyReports.contains(where: { $0.dayKey == window.dayKey }) {
            return
        }

        guard !isGeneratingDailyReport else {
            return
        }

        isGeneratingDailyReport = true
        defer { isGeneratingDailyReport = false }

        do {
            let context = try await loadDailyReportContext(for: window)
            let generation = try await buildDailyReport(context: context, window: window)
            let generatedAtMs = Int(Date().timeIntervalSince1970 * 1000)
            let report = IntentGeneratedDailyReport(
                id: window.dayKey,
                dayKey: window.dayKey,
                title: window.title,
                headline: generation.payload.headline,
                overview: generation.payload.overview,
                stats: generation.payload.stats,
                whatWentWell: generation.payload.whatWentWell,
                whatDidntGoWell: generation.payload.whatDidntGoWell,
                improvements: generation.payload.improvements,
                intervalStartMs: Int(window.startDate.timeIntervalSince1970 * 1000),
                intervalEndMs: Int(window.endDate.timeIntervalSince1970 * 1000),
                generatedAtMs: generatedAtMs,
                source: generation.source
            )

            dailyReports = try dailyReportStore.upsert(report)

            if generation.source == .fallback, isAIConfigured {
                lastNotice = "\(report.title) was saved with a fallback summary because AI generation failed."
            } else {
                lastNotice = "\(report.title) is ready."
            }
            lastError = nil

            if notifyWhenReady {
                await notifyDailyReportReady(report)
            }
        } catch {
            lastNotice = nil
            lastError = displayMessage(for: error)
        }
    }

    private func loadDailyReportContext(
        for window: IntentDailyReportWindow
    ) async throws -> IntentDailyReportContext {
        let response: IntentDailyReportContextEnvelope = try await post(
            path: "/intent/device/daily-report",
            body: IntentDeviceDailyReportRequest(
                deviceId: configuration.deviceId,
                deviceSecret: configuration.deviceSecret,
                startTimeMs: Int(window.startDate.timeIntervalSince1970 * 1000),
                endTimeMs: Int(window.endDate.timeIntervalSince1970 * 1000)
            )
        )
        return response.state
    }

    private func buildDailyReport(
        context: IntentDailyReportContext,
        window: IntentDailyReportWindow
    ) async throws -> (payload: IntentDailyReportPayload, source: IntentGeneratedDailyReport.Source) {
        do {
            let payload = try await IntentDailyReportGenerationService().generate(
                context: context,
                window: window
            )
            return (payload, .ai)
        } catch IntentDailyReportError.missingAPIKey {
            return (IntentDailyReportFallbackBuilder.build(context: context, window: window), .fallback)
        } catch {
            return (IntentDailyReportFallbackBuilder.build(context: context, window: window), .fallback)
        }
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        guard (200 ... 299).contains(httpResponse.statusCode) else {
            if let apiError = try? JSONDecoder().decode(IntentAPIError.self, from: data) {
                throw NSError(
                    domain: "IntentAPI",
                    code: httpResponse.statusCode,
                    userInfo: [NSLocalizedDescriptionKey: apiError.error]
                )
            }

            throw NSError(
                domain: "IntentAPI",
                code: httpResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "Request failed with status \(httpResponse.statusCode)."]
            )
        }
    }

    private func runShortcut(named name: String) async throws {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw NSError(
                domain: "IntentShortcut",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Shortcut name cannot be empty."]
            )
        }

        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
            process.arguments = ["run", trimmedName]

            let errorPipe = Pipe()
            process.standardError = errorPipe

            try process.run()
            process.waitUntilExit()

            guard process.terminationStatus == 0 else {
                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                let errorOutput = String(data: errorData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                throw NSError(
                    domain: "IntentShortcut",
                    code: Int(process.terminationStatus),
                    userInfo: [
                        NSLocalizedDescriptionKey: errorOutput?.isEmpty == false
                            ? Self.shortcutFailureMessage(from: errorOutput!, shortcutName: trimmedName)
                            : "Shortcut \(trimmedName) failed."
                    ]
                )
            }
        }.value
    }

    private func ensureShortcutExists(named name: String) async throws -> Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            return false
        }

        if unavailableShortcuts.contains(trimmedName) {
            return false
        }

        let now = Date()
        if let lastShortcutRefreshAt,
           now.timeIntervalSince(lastShortcutRefreshAt) < shortcutRefreshIntervalSeconds,
           !knownShortcutNames.isEmpty {
            return knownShortcutNames.contains(trimmedName)
        }

        let shortcutNames = try await loadShortcutNames()
        knownShortcutNames = shortcutNames
        lastShortcutRefreshAt = now

        if shortcutNames.contains(trimmedName) {
            unavailableShortcuts.remove(trimmedName)
            return true
        }

        return false
    }

    private func loadShortcutNames() async throws -> Set<String> {
        try await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
            process.arguments = ["list"]

            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            try process.run()
            process.waitUntilExit()

            guard process.terminationStatus == 0 else {
                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                let errorOutput = String(data: errorData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                throw NSError(
                    domain: "IntentShortcut",
                    code: Int(process.terminationStatus),
                    userInfo: [
                        NSLocalizedDescriptionKey: errorOutput?.isEmpty == false
                            ? errorOutput!
                            : "Failed to list Apple Shortcuts."
                    ]
                )
            }

            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: outputData, encoding: .utf8) ?? ""

            return Set(
                output
                    .split(whereSeparator: \.isNewline)
                    .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            )
        }.value
    }

    nonisolated private static func shortcutFailureMessage(from output: String, shortcutName: String) -> String {
        if output.contains("Couldn't find shortcut") || output.contains("Couldn’t find shortcut") {
            return "Shortcut \"\(shortcutName)\" was not found in Apple Shortcuts. Create it or update the configured shortcut name."
        }

        return output
    }

    private func notifyDailyReportReady(_ report: IntentGeneratedDailyReport) async {
        let center = UNUserNotificationCenter.current()
        let authorizationStatus = await notificationAuthorizationStatus(for: center)
        if authorizationStatus == .denied {
            return
        }

        if authorizationStatus == .notDetermined {
            let granted = await requestNotificationAuthorization(for: center)
            guard granted else {
                return
            }
        }

        let content = UNMutableNotificationContent()
        content.title = report.title
        content.body = report.headline
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "daily-report-\(report.dayKey)",
            content: content,
            trigger: nil
        )

        await addNotificationRequest(request, to: center)
    }

    private func notificationAuthorizationStatus(
        for center: UNUserNotificationCenter
    ) async -> UNAuthorizationStatus {
        await withCheckedContinuation { continuation in
            center.getNotificationSettings { settings in
                continuation.resume(returning: settings.authorizationStatus)
            }
        }
    }

    private func requestNotificationAuthorization(
        for center: UNUserNotificationCenter
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                continuation.resume(returning: granted)
            }
        }
    }

    private func addNotificationRequest(
        _ request: UNNotificationRequest,
        to center: UNUserNotificationCenter
    ) async {
        await withCheckedContinuation { continuation in
            center.add(request) { _ in
                continuation.resume()
            }
        }
    }
}

private struct IntentOKResponse: Decodable {
    let ok: Bool
}
