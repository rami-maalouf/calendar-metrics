import Combine
import Foundation

@MainActor
final class IntentCalendarAppModel: ObservableObject {
    @Published private(set) var session: PlanningSessionState
    @Published private(set) var availableCalendars: [CalendarDescriptor] = []
    @Published var isLoading = false
    @Published var isPlanning = false
    @Published var isApplying = false
    @Published var errorMessage: String?
    @Published var selectedTemplateRuleBlock: TemplateBlock?
    @Published var showingSettings = false
    @Published var showingDrafts = false
    @Published var showingArchive = false

    let draftManager: DraftManager
    let transcriberService: TranscriberService
    let vaultManager: VaultManager
    let settingsStore: AppSettingsStore
    let calendarPermissionsManager: CalendarPermissionsManager

    private let calendarRepository: CalendarRepository
    private let llmService: LLMService
    private var cancellables: Set<AnyCancellable> = []

    init(
        draftManager: DraftManager,
        transcriberService: TranscriberService,
        vaultManager: VaultManager,
        settingsStore: AppSettingsStore,
        calendarPermissionsManager: CalendarPermissionsManager,
        calendarRepository: CalendarRepository,
        llmService: LLMService
    ) {
        self.draftManager = draftManager
        self.transcriberService = transcriberService
        self.vaultManager = vaultManager
        self.settingsStore = settingsStore
        self.calendarPermissionsManager = calendarPermissionsManager
        self.calendarRepository = calendarRepository
        self.llmService = llmService
        self.session = PlanningSessionState.empty(for: Calendar.current.startOfDay(for: Date().journalDate))
        bindDependencyChanges()
    }

    convenience init(
        draftManager: DraftManager,
        transcriberService: TranscriberService,
        vaultManager: VaultManager,
        settingsStore: AppSettingsStore
    ) {
        self.init(
            draftManager: draftManager,
            transcriberService: transcriberService,
            vaultManager: vaultManager,
            settingsStore: settingsStore,
            calendarPermissionsManager: CalendarPermissionsManager(),
            calendarRepository: CalendarRepository(),
            llmService: LLMService()
        )
    }

    var configuration: IntentCalendarConfiguration {
        settingsStore.configuration
    }

    var shouldShowOnboarding: Bool {
        if AppConstants.isUITesting {
            return false
        }

        return !settingsStore.hasCompletedOnboarding ||
        settingsStore.selectedTemplateCalendarID == nil ||
        settingsStore.selectedPlanningCalendarID == nil ||
        calendarPermissionsManager.accessState == .notDetermined ||
        calendarPermissionsManager.accessState == .writeOnly ||
        calendarPermissionsManager.accessState == .denied ||
        calendarPermissionsManager.accessState == .restricted
    }

    func start() {
        if AppConstants.isUITesting {
            seedUITestingSession()
            return
        }

        Task {
            await refreshCalendars()
            await reloadDay(keepConversation: false)
            await consumeSharedPayloadIfNeeded()
        }
    }

    func requestCalendarAccess() async {
        do {
            _ = try await calendarPermissionsManager.requestAccess(using: calendarRepository.eventStore)
            await refreshCalendars()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refreshCalendars() async {
        calendarPermissionsManager.refresh()
        availableCalendars = calendarRepository.calendars()

        if settingsStore.selectedConstraintCalendarIDs.isEmpty {
            settingsStore.selectedConstraintCalendarIDs = calendarRepository.defaultConstraintCalendarIDs(
                templateCalendarID: settingsStore.selectedTemplateCalendarID,
                planningCalendarID: settingsStore.selectedPlanningCalendarID
            )
        }
    }

    func selectDate(_ date: Date) async {
        let calendar = Calendar.current
        let normalized = calendar.startOfDay(for: date.journalDate)
        session = PlanningSessionState.empty(for: normalized)
        await reloadDay(keepConversation: false)
    }

    func reloadDay(keepConversation: Bool = true) async {
        isLoading = true
        defer { isLoading = false }

        do {
            let priorMessages = keepConversation ? session.messages : []
            let summary = keepConversation ? session.summary : ""
            let dayContext = try calendarRepository.loadDayContext(
                for: session.selectedDate,
                configuration: settingsStore.configuration
            )

            let planningWindows = PlanningEngine.planningWindows(
                templateBlocks: dayContext.templateBlocks,
                commitments: dayContext.fixedCommitments,
                date: session.selectedDate
            )

            session = PlanningSessionState(
                selectedDate: session.selectedDate,
                messages: priorMessages,
                templateBlocks: dayContext.templateBlocks,
                planningWindows: planningWindows,
                fixedCommitments: dayContext.fixedCommitments,
                existingPlannedEvents: dayContext.existingPlannedEvents,
                proposedBlocks: [],
                previewOperations: [],
                pendingQuestions: [],
                summary: summary
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func sendCurrentDraftToPlanner() async {
        let userText = draftManager.currentDraft?.content.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !userText.isEmpty else {
            errorMessage = "Add some context about the day before asking IntentCalendar to plan."
            return
        }

        errorMessage = nil
        isPlanning = true
        defer { isPlanning = false }

        session.messages.append(PlanningMessage(role: .user, content: userText))
        draftManager.updateCurrentDraft(content: "")

        do {
            let notes = try vaultManager.fetchDailyNotesContext(
                for: session.selectedDate,
                count: settingsStore.selectedDateContextWindow
            )

            let snapshot = PlanningEngine.buildContextSnapshot(
                date: session.selectedDate,
                planningWindows: session.planningWindows,
                fixedCommitments: session.fixedCommitments,
                existingPlannedEvents: session.existingPlannedEvents,
                conversation: session.messages,
                obsidianContext: notes
            )

            let response = try await llmService.planDay(
                snapshot: snapshot,
                model: settingsStore.plannerModel
            )

            session.summary = response.summary

            switch response.outcome {
            case .questions:
                session.pendingQuestions = response.questions
                session.proposedBlocks = []
                session.previewOperations = []
                let messageBody = ([response.summary] + response.questions.map(\.prompt))
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n\n")
                session.messages.append(PlanningMessage(role: .assistant, content: messageBody))
            case .plan:
                let validation = try PlanningEngine.validate(
                    plannerResponse: response,
                    planningWindows: session.planningWindows,
                    fixedCommitments: session.fixedCommitments,
                    existingPlannedEvents: session.existingPlannedEvents,
                    planningCalendarID: settingsStore.selectedPlanningCalendarID
                )
                session.pendingQuestions = []
                session.proposedBlocks = validation.proposedBlocks
                session.previewOperations = validation.previewOperations
                session.messages.append(PlanningMessage(role: .assistant, content: response.summary))
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func applyPreview() async {
        guard !session.previewOperations.isEmpty else { return }

        isApplying = true
        defer { isApplying = false }

        do {
            try calendarRepository.apply(writeOperations: session.previewOperations)
            session.messages.append(
                PlanningMessage(
                    role: .system,
                    content: "Applied \(session.proposedBlocks.count) blocks to your planning calendar."
                )
            )
            await reloadDay(keepConversation: true)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func completeOnboarding() {
        settingsStore.hasCompletedOnboarding = true
    }

    func finishOnboarding(apiKey: String) async {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            errorMessage = "Add your OpenAI API key before starting IntentCalendar."
            return
        }

        KeychainManager.shared.saveAPIKey(trimmedKey)
        completeOnboarding()
        await refreshCalendars()
        await reloadDay(keepConversation: false)
    }

    var currentErrorNeedsSettingsShortcut: Bool {
        guard let message = errorMessage?.lowercased() else {
            return false
        }

        return message.contains("api key") || message.contains("openai")
    }

    func saveTemplateRule(for block: TemplateBlock, rule: TemplateBlockRule) async {
        do {
            try calendarRepository.updateTemplateRule(for: block, rule: rule)
            selectedTemplateRuleBlock = nil
            await reloadDay(keepConversation: true)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func ingestCapturedText(_ text: String) {
        let currentText = draftManager.currentDraft?.content ?? ""
        let combined = currentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? text
            : "\(currentText)\n\n\(text)"
        draftManager.updateCurrentDraft(content: combined)
    }

    func consumeSharedPayloadIfNeeded() async {
        if let sharedText = SharedPayloadStore.consumeSharedText(), !sharedText.isEmpty {
            ingestCapturedText(sharedText)
        }
    }

    func handleSharedAudio(filename: String) async {
        guard let audioURL = SharedPayloadStore.audioURL(for: filename) else {
            errorMessage = "Shared audio file could not be located."
            return
        }

        do {
            let text = try await transcriberService.transcribe(audioURL: audioURL)
            ingestCapturedText(text)
            try? FileManager.default.removeItem(at: audioURL)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func seedUITestingSession() {
        let calendar = Calendar.current
        let selectedDate = calendar.startOfDay(for: Date().journalDate)

        let templateCalendarID = "ui-test-template"
        let planningCalendarID = "ui-test-planning"
        settingsStore.hasCompletedOnboarding = true
        settingsStore.selectedTemplateCalendarID = templateCalendarID
        settingsStore.selectedPlanningCalendarID = planningCalendarID
        settingsStore.selectedConstraintCalendarIDs = ["ui-test-constraints"]

        availableCalendars = [
            CalendarDescriptor(
                id: templateCalendarID,
                title: "Typical Day",
                source: "IntentCalendar Preview",
                allowsContentModifications: true,
                colorHex: "#1F6FEB"
            ),
            CalendarDescriptor(
                id: planningCalendarID,
                title: "IntentCalendar Plan",
                source: "IntentCalendar Preview",
                allowsContentModifications: true,
                colorHex: "#F97316"
            )
        ]

        let workoutStart = calendar.date(bySettingHour: 7, minute: 0, second: 0, of: selectedDate) ?? selectedDate
        let workoutEnd = calendar.date(bySettingHour: 8, minute: 0, second: 0, of: selectedDate) ?? selectedDate
        let focusStart = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: selectedDate) ?? selectedDate
        let focusEnd = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: selectedDate) ?? selectedDate
        let prayerStart = calendar.date(bySettingHour: 13, minute: 0, second: 0, of: selectedDate) ?? selectedDate
        let prayerEnd = calendar.date(bySettingHour: 13, minute: 30, second: 0, of: selectedDate) ?? selectedDate
        let adminStart = calendar.date(bySettingHour: 16, minute: 0, second: 0, of: selectedDate) ?? selectedDate
        let adminEnd = calendar.date(bySettingHour: 18, minute: 0, second: 0, of: selectedDate) ?? selectedDate
        let meetingStart = calendar.date(bySettingHour: 15, minute: 0, second: 0, of: selectedDate) ?? selectedDate
        let meetingEnd = calendar.date(bySettingHour: 15, minute: 30, second: 0, of: selectedDate) ?? selectedDate

        let templateBlocks = [
            TemplateBlock(
                id: "block-workout",
                calendarItemIdentifier: "block-workout",
                calendarID: templateCalendarID,
                title: "Gym",
                startDate: workoutStart,
                endDate: workoutEnd,
                notes: nil,
                rule: TemplateBlockRule(
                    isLocked: false,
                    blockLabel: "Morning workout",
                    allowedActivities: ["Gym", "Cardio", "Mobility"],
                    planningHint: "Start the day with movement.",
                    destinationCalendarID: planningCalendarID,
                    minimumDurationMinutes: 45,
                    maximumDurationMinutes: 90
                )
            ),
            TemplateBlock(
                id: "block-focus",
                calendarItemIdentifier: "block-focus",
                calendarID: templateCalendarID,
                title: "Deep Work",
                startDate: focusStart,
                endDate: focusEnd,
                notes: nil,
                rule: TemplateBlockRule(
                    isLocked: false,
                    blockLabel: "Focus block",
                    allowedActivities: ["Deep work", "Writing", "Product work"],
                    planningHint: "Reserve this for the most valuable task.",
                    destinationCalendarID: planningCalendarID,
                    minimumDurationMinutes: 60,
                    maximumDurationMinutes: 180
                )
            ),
            TemplateBlock(
                id: "block-prayer",
                calendarItemIdentifier: "block-prayer",
                calendarID: templateCalendarID,
                title: "Prayer",
                startDate: prayerStart,
                endDate: prayerEnd,
                notes: nil,
                rule: TemplateBlockRule(
                    isLocked: true,
                    blockLabel: "Prayer",
                    allowedActivities: [],
                    planningHint: "Do not schedule over this block.",
                    destinationCalendarID: nil,
                    minimumDurationMinutes: nil,
                    maximumDurationMinutes: nil
                )
            ),
            TemplateBlock(
                id: "block-admin",
                calendarItemIdentifier: "block-admin",
                calendarID: templateCalendarID,
                title: "Admin",
                startDate: adminStart,
                endDate: adminEnd,
                notes: nil,
                rule: TemplateBlockRule(
                    isLocked: false,
                    blockLabel: "Admin and follow-up",
                    allowedActivities: ["Email", "Errands", "Follow-up"],
                    planningHint: "Use this for lighter tasks and cleanup.",
                    destinationCalendarID: planningCalendarID,
                    minimumDurationMinutes: 30,
                    maximumDurationMinutes: 120
                )
            )
        ]

        let fixedCommitments = [
            ExistingCommitment(
                id: "fixed-meeting",
                eventIdentifier: "fixed-meeting",
                calendarID: "ui-test-constraints",
                calendarTitle: "Constraints",
                title: "Team sync",
                startDate: meetingStart,
                endDate: meetingEnd,
                isAllDay: false,
                isAppOwned: false
            ),
            ExistingCommitment(
                id: "fixed-prayer",
                eventIdentifier: "fixed-prayer",
                calendarID: templateCalendarID,
                calendarTitle: "Template",
                title: "Prayer",
                startDate: prayerStart,
                endDate: prayerEnd,
                isAllDay: false,
                isAppOwned: false
            )
        ]

        let planningWindows = PlanningEngine.planningWindows(
            templateBlocks: templateBlocks,
            commitments: fixedCommitments,
            date: selectedDate
        )

        let plannerResponse = PlannerResponse(
            outcome: .plan,
            summary: "Sample plan seeded for UI testing.",
            questions: [],
            plannedBlocks: [
                PlannerSuggestedBlock(
                    id: "planned-workout",
                    title: "Upper body session",
                    windowID: "block-workout",
                    startLocalTime: "07:00",
                    endLocalTime: "08:00",
                    detail: "Strength training and a short cool-down.",
                    rationale: "You said movement early keeps the rest of the day on track."
                ),
                PlannerSuggestedBlock(
                    id: "planned-focus",
                    title: "Ship calendar planning v1",
                    windowID: "block-focus",
                    startLocalTime: "09:00",
                    endLocalTime: "11:00",
                    detail: "Finish the scheduling flow and review edge cases.",
                    rationale: "This is the highest-leverage work on the board."
                ),
                PlannerSuggestedBlock(
                    id: "planned-admin",
                    title: "Inbox and errands",
                    windowID: "block-admin",
                    startLocalTime: "16:00",
                    endLocalTime: "17:00",
                    detail: "Email follow-up, calendar cleanup, and one quick errand.",
                    rationale: "These tasks fit the lower-intensity block."
                )
            ]
        )

        let validation = try? PlanningEngine.validate(
            plannerResponse: plannerResponse,
            planningWindows: planningWindows,
            fixedCommitments: fixedCommitments,
            existingPlannedEvents: [],
            planningCalendarID: planningCalendarID
        )

        session = PlanningSessionState(
            selectedDate: selectedDate,
            messages: [
                PlanningMessage(
                    role: .user,
                    content: "I want to get a workout in early, reserve my best focus for shipping work, and keep late afternoon lighter."
                ),
                PlanningMessage(
                    role: .assistant,
                    content: plannerResponse.summary
                )
            ],
            templateBlocks: templateBlocks,
            planningWindows: planningWindows,
            fixedCommitments: fixedCommitments,
            existingPlannedEvents: [],
            proposedBlocks: validation?.proposedBlocks ?? [],
            previewOperations: validation?.previewOperations ?? [],
            pendingQuestions: [],
            summary: plannerResponse.summary
        )
    }

    private func bindDependencyChanges() {
        settingsStore.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        calendarPermissionsManager.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }
}
