import EventKit
import Foundation

final class CalendarRepository {
    let eventStore: EKEventStore

    init(eventStore: EKEventStore = EKEventStore()) {
        self.eventStore = eventStore
    }

    func calendars() -> [CalendarDescriptor] {
        eventStore.calendars(for: .event)
            .sorted { lhs, rhs in
                if lhs.allowsContentModifications != rhs.allowsContentModifications {
                    return lhs.allowsContentModifications && !rhs.allowsContentModifications
                }
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
            .map { calendar in
                CalendarDescriptor(
                    id: calendar.calendarIdentifier,
                    title: calendar.title,
                    source: calendar.source.title,
                    allowsContentModifications: calendar.allowsContentModifications,
                    colorHex: Self.hexString(for: calendar.cgColor)
                )
            }
    }

    func defaultConstraintCalendarIDs(
        templateCalendarID: String?,
        planningCalendarID: String?
    ) -> [String] {
        calendars()
            .filter { descriptor in
                descriptor.id != templateCalendarID && descriptor.id != planningCalendarID
            }
            .map(\.id)
    }

    func loadDayContext(
        for date: Date,
        configuration: IntentCalendarConfiguration
    ) throws -> EventDayContext {
        let interval = dayInterval(for: date)
        let allCalendars = eventStore.calendars(for: .event)

        let templateCalendar = allCalendars.first(where: { $0.calendarIdentifier == configuration.selectedTemplateCalendarID })
        let planningCalendar = allCalendars.first(where: { $0.calendarIdentifier == configuration.selectedPlanningCalendarID })

        let constraintIDs = configuration.selectedConstraintCalendarIDs.isEmpty
            ? defaultConstraintCalendarIDs(
                templateCalendarID: configuration.selectedTemplateCalendarID,
                planningCalendarID: configuration.selectedPlanningCalendarID
            )
            : configuration.selectedConstraintCalendarIDs

        let constraintCalendars = allCalendars.filter { constraintIDs.contains($0.calendarIdentifier) }

        let templateBlocks = try templateCalendar.map {
            try fetchTemplateBlocks(
                for: interval,
                calendar: $0
            )
        } ?? []

        let constraintEvents = fetchEvents(for: interval, calendars: constraintCalendars)
        let existingPlannedEvents = planningCalendar.map {
            fetchEvents(for: interval, calendars: [$0]).filter(\.isIntentCalendarOwned)
        } ?? []

        let fixedCommitments = constraintEvents.map(Self.commitment(from:)) + templateBlocks
            .filter(\.rule.isLocked)
            .map { block in
                ExistingCommitment(
                    id: "template-\(block.id)",
                    eventIdentifier: block.calendarItemIdentifier,
                    calendarID: block.calendarID,
                    calendarTitle: "Template",
                    title: block.displayLabel,
                    startDate: block.startDate,
                    endDate: block.endDate,
                    isAllDay: false,
                    isAppOwned: false
                )
            }

        return EventDayContext(
            templateBlocks: templateBlocks,
            fixedCommitments: fixedCommitments.sorted { $0.startDate < $1.startDate },
            existingPlannedEvents: existingPlannedEvents.map(Self.commitment(from:)).sorted { $0.startDate < $1.startDate }
        )
    }

    func updateTemplateRule(for block: TemplateBlock, rule: TemplateBlockRule) throws {
        guard let event = eventStore.calendarItem(withIdentifier: block.calendarItemIdentifier) as? EKEvent else {
            return
        }

        let noteBody = TemplateRuleNoteCodec.encode(rule: rule, existingNotes: event.notes)
        event.notes = noteBody
        try eventStore.save(event, span: .thisEvent)
    }

    func apply(writeOperations: [CalendarWriteOperation]) throws {
        let calendarsByID = Dictionary(uniqueKeysWithValues: eventStore.calendars(for: .event).map { ($0.calendarIdentifier, $0) })

        for operation in writeOperations {
            switch operation.operationType {
            case .delete:
                guard let eventIdentifier = operation.eventIdentifier,
                      let event = eventStore.event(withIdentifier: eventIdentifier) else {
                    continue
                }
                try eventStore.remove(event, span: .thisEvent)
            case .create:
                guard let calendar = calendarsByID[operation.calendarID] else {
                    continue
                }
                let event = EKEvent(eventStore: eventStore)
                event.calendar = calendar
                event.title = operation.title
                event.startDate = operation.startDate
                event.endDate = operation.endDate
                event.notes = operation.notes
                try eventStore.save(event, span: .thisEvent)
            case .update:
                guard let eventIdentifier = operation.eventIdentifier,
                      let event = eventStore.event(withIdentifier: eventIdentifier) else {
                    continue
                }
                event.title = operation.title
                event.startDate = operation.startDate
                event.endDate = operation.endDate
                event.notes = operation.notes
                try eventStore.save(event, span: .thisEvent)
            }
        }
    }

    func planningCalendarDescriptor(id: String?) -> CalendarDescriptor? {
        calendars().first(where: { $0.id == id })
    }

    private func fetchTemplateBlocks(
        for interval: DateInterval,
        calendar: EKCalendar
    ) throws -> [TemplateBlock] {
        fetchEvents(for: interval, calendars: [calendar]).map { event in
            let parsed = TemplateRuleNoteCodec.decode(from: event.notes)
            return TemplateBlock(
                id: event.eventIdentifier,
                calendarItemIdentifier: event.calendarItemIdentifier,
                calendarID: event.calendar.calendarIdentifier,
                title: event.title,
                startDate: event.startDate,
                endDate: event.endDate,
                notes: parsed.userNotes,
                rule: parsed.rule ?? .flexibleDefault
            )
        }
    }

    private func fetchEvents(for interval: DateInterval, calendars: [EKCalendar]) -> [EKEvent] {
        guard !calendars.isEmpty else { return [] }
        let predicate = eventStore.predicateForEvents(withStart: interval.start, end: interval.end, calendars: calendars)
        return eventStore.events(matching: predicate)
            .sorted { lhs, rhs in
                if lhs.startDate == rhs.startDate {
                    return lhs.endDate < rhs.endDate
                }
                return lhs.startDate < rhs.startDate
            }
    }

    private static func commitment(from event: EKEvent) -> ExistingCommitment {
        ExistingCommitment(
            id: event.eventIdentifier,
            eventIdentifier: event.eventIdentifier,
            calendarID: event.calendar.calendarIdentifier,
            calendarTitle: event.calendar.title,
            title: event.title,
            startDate: event.startDate,
            endDate: event.endDate,
            isAllDay: event.isAllDay,
            isAppOwned: event.isIntentCalendarOwned
        )
    }

    private func dayInterval(for date: Date) -> DateInterval {
        let start = date.journalDayStart
        let end = date.journalDayEnd
        return DateInterval(start: start, end: end)
    }

    private static func hexString(for color: CGColor) -> String? {
        guard let components = color.components, components.count >= 3 else {
            return nil
        }
        let r = Int((components[0] * 255.0).rounded())
        let g = Int((components[1] * 255.0).rounded())
        let b = Int((components[2] * 255.0).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}

enum TemplateRuleNoteCodec {
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder = JSONDecoder()

    static func encode(rule: TemplateBlockRule, existingNotes: String?) -> String {
        let cleanNotes = decode(from: existingNotes).userNotes
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let payload: String
        if let data = try? encoder.encode(rule), let json = String(data: data, encoding: .utf8) {
            payload = "\(AppConstants.Metadata.templateRuleStart)\n\(json)\n\(AppConstants.Metadata.templateRuleEnd)"
        } else {
            payload = "\(AppConstants.Metadata.templateRuleStart)\n{}\n\(AppConstants.Metadata.templateRuleEnd)"
        }

        guard !cleanNotes.isEmpty else {
            return payload
        }

        return "\(cleanNotes)\n\n\(payload)"
    }

    static func decode(from notes: String?) -> (rule: TemplateBlockRule?, userNotes: String) {
        guard let notes, !notes.isEmpty else {
            return (nil, "")
        }

        guard let startRange = notes.range(of: AppConstants.Metadata.templateRuleStart),
              let endRange = notes.range(of: AppConstants.Metadata.templateRuleEnd)
        else {
            return (nil, notes)
        }

        let jsonStart = startRange.upperBound
        let json = notes[jsonStart..<endRange.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let stripped = (notes[..<startRange.lowerBound] + notes[endRange.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let decodedRule = json.data(using: .utf8).flatMap { try? decoder.decode(TemplateBlockRule.self, from: $0) }
        return (decodedRule, stripped)
    }
}

extension EKEvent {
    var isIntentCalendarOwned: Bool {
        (notes ?? "").contains(AppConstants.Metadata.plannedEventStart)
    }
}
