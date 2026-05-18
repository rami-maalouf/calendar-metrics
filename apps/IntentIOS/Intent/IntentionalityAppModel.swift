//
//  IntentionalityAppModel.swift
//  Intent
//
//  Created by Codex on 2026-05-11.
//

import Combine
import ConvexMobile
import Foundation

@MainActor
final class IntentionalityAppModel: ObservableObject {
    @Published var configuration: IntentConfiguration {
        didSet {
            configuration.persist()
        }
    }

    @Published var snapshot: IntentionalitySnapshot?
    @Published var connectionStatus = "Needs setup"
    @Published var lastError: String?
    @Published var lastNotice: String?
    @Published var isPairing = false
    @Published var isRecording = false
    @Published var pendingScore = 7.0

    private var convexClient: ConvexClient?
    private var convexDeploymentURL: String?
    private var snapshotSubscription: AnyCancellable?
    private var webSocketStateSubscription: AnyCancellable?
    private var lastObservedWebSocketState: WebSocketState?

    init() {
        let configuration = IntentConfiguration.load()
        self.configuration = configuration
        if configuration.sampleDataEnabled {
            snapshot = IntentionalitySampleData.snapshot(windowDays: configuration.windowDays)
            connectionStatus = "Sample data"
        } else if configuration.isPaired {
            connectionStatus = "Ready"
        }
    }

    var isPaired: Bool {
        configuration.isPaired
    }

    var timeZoneOffsetMinutes: Double {
        Double(TimeZone.current.secondsFromGMT(for: Date()) / 60)
    }

    func start() {
        if configuration.sampleDataEnabled {
            useSampleData()
            return
        }

        guard configuration.isPaired else {
            connectionStatus = "Needs setup"
            return
        }

        ensureRealtimeConnection(forceReconnect: false)
    }

    func stop() {
        snapshotSubscription?.cancel()
        snapshotSubscription = nil
        webSocketStateSubscription?.cancel()
        webSocketStateSubscription = nil
        convexClient = nil
        convexDeploymentURL = nil
        lastObservedWebSocketState = nil
    }

    func updateConfiguration(_ update: (inout IntentConfiguration) -> Void) {
        let previous = configuration
        var next = configuration
        update(&next)
        configuration = next

        let identityChanged =
            previous.backendBaseURL != next.backendBaseURL ||
            previous.deviceId != next.deviceId ||
            previous.deviceSecret != next.deviceSecret ||
            previous.windowDays != next.windowDays

        if next.sampleDataEnabled {
            useSampleData()
            return
        }

        if previous.sampleDataEnabled && !next.sampleDataEnabled {
            snapshot = nil
            lastNotice = nil
            lastError = nil
        }

        if !next.isPaired {
            stop()
            connectionStatus = "Needs setup"
            return
        }

        ensureRealtimeConnection(forceReconnect: identityChanged)
    }

    func pair() async {
        guard !isPairing else {
            return
        }

        isPairing = true
        defer { isPairing = false }

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
                    platform: "ios",
                    settings: IntentBootstrapSettings(
                        autoStartFocus: false,
                        autoCompleteFocus: false,
                        autoShowReview: false,
                        bundleId: Bundle.main.bundleIdentifier ?? "studio.orbitlabs.Intent.ios"
                    )
                )
            )

            updateConfiguration { configuration in
                configuration.deviceId = response.device.deviceId
                configuration.deviceSecret = response.device.deviceSecret
            }

            lastError = nil
            lastNotice = "Paired"
            connectionStatus = "Connecting"
            ensureRealtimeConnection(forceReconnect: true)
        } catch {
            lastNotice = nil
            lastError = displayMessage(for: error)
            connectionStatus = "Setup failed"
        }
    }

    func recordCurrentHour() async {
        if configuration.sampleDataEnabled {
            snapshot = IntentionalitySampleData.snapshot(
                windowDays: configuration.windowDays,
                currentHourScore: pendingScore
            )
            lastError = nil
            lastNotice = "Recorded sample \(formatScore(pendingScore))/10"
            connectionStatus = "Sample data"
            return
        }

        guard configuration.isPaired else {
            connectionStatus = "Needs setup"
            return
        }

        ensureRealtimeConnection(forceReconnect: false)

        guard let convexClient else {
            lastNotice = nil
            lastError = "Live sync client is not available."
            return
        }

        isRecording = true
        defer { isRecording = false }

        do {
            let _: IntentionalityRecordResponse = try await convexClient.mutation(
                "intent:recordIntentionalityFromDevice",
                with: [
                    "deviceId": configuration.deviceId,
                    "deviceSecret": configuration.deviceSecret,
                    "score": pendingScore
                ]
            )
            lastError = nil
            lastNotice = "Recorded \(formatScore(pendingScore))/10"
        } catch {
            lastNotice = nil
            lastError = displayMessage(for: error)
        }
    }

    func setWindowDays(_ days: Int) {
        updateConfiguration { configuration in
            configuration.windowDays = min(180, max(1, days))
        }
    }

    private func useSampleData() {
        stop()
        snapshot = IntentionalitySampleData.snapshot(windowDays: configuration.windowDays)
        connectionStatus = "Sample data"
        lastError = nil
    }

    private var subscriptionArguments: [String: ConvexEncodable?] {
        [
            "deviceId": configuration.deviceId,
            "deviceSecret": configuration.deviceSecret,
            "windowDays": Double(configuration.windowDays),
            "timeZoneOffsetMinutes": timeZoneOffsetMinutes
        ]
    }

    private func ensureRealtimeConnection(forceReconnect: Bool) {
        guard configuration.isPaired else {
            stop()
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

            stop()

            let client = ConvexClient(deploymentUrl: deploymentURL)
            convexClient = client
            convexDeploymentURL = deploymentURL
            connectionStatus = "Connecting"

            webSocketStateSubscription = client.watchWebSocketState()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] state in
                    guard let self else { return }
                    Task { @MainActor in
                        self.handleWebSocketState(state)
                    }
                }

            snapshotSubscription = client.subscribe(
                to: "intent:getIntentionalitySnapshotJson",
                with: subscriptionArguments,
                yielding: String.self
            )
            .receive(on: DispatchQueue.main)
            .sink(
                receiveCompletion: { [weak self] completion in
                    guard let self else { return }
                    self.handleRealtimeCompletion(completion)
                },
                receiveValue: { [weak self] snapshotJSON in
                    guard let self else { return }
                    self.applySnapshotJSON(snapshotJSON)
                }
            )
        } catch {
            stop()
            connectionStatus = "Disconnected"
            lastNotice = nil
            lastError = displayMessage(for: error)
        }
    }

    private func handleWebSocketState(_ state: WebSocketState) {
        defer {
            lastObservedWebSocketState = state
        }

        switch state {
        case .connected:
            connectionStatus = "Connected"
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

    private func applySnapshotJSON(_ snapshotJSON: String) {
        do {
            let data = Data(snapshotJSON.utf8)
            snapshot = try JSONDecoder().decode(IntentionalitySnapshot.self, from: data)
            lastError = nil
        } catch {
            lastNotice = nil
            lastError = displayMessage(for: error)
        }
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

        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
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

    private func validate(response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = errorMessage(from: data) ?? HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode)
            throw NSError(
                domain: "IntentAPI",
                code: httpResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }
    }

    private func errorMessage(from data: Data) -> String? {
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let error = object["error"] as? String,
            !error.isEmpty
        else {
            return nil
        }

        return error
    }

    private func displayMessage(for error: Error) -> String {
        let nsError = error as NSError
        if let description = nsError.userInfo[NSLocalizedDescriptionKey] as? String,
           !description.isEmpty {
            return description
        }

        return error.localizedDescription
    }

    private func formatScore(_ value: Double) -> String {
        if value.rounded() == value {
            return String(Int(value))
        }

        return String(format: "%.1f", value)
    }
}
