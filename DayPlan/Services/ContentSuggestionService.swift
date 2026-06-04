import Foundation
import SwiftData

struct SuggestedChecklistItem: Identifiable, Equatable {
    let eventKey: String
    let externalID: String
    let title: String
    let excerpt: String
    let sourceName: String
    let category: ContentCategory
    let url: URL?
    let receivedAt: Date
    let score: Int
    let reason: String

    var id: String { eventKey }
}

@MainActor
enum ContentSuggestionService {
    static let minimumScore = 45

    private static let actionKeywords = [
        "appointment",
        "call",
        "complete",
        "confirm",
        "deadline",
        "due",
        "email",
        "finish",
        "follow up",
        "follow-up",
        "meeting",
        "reminder",
        "reply",
        "respond",
        "review",
        "schedule",
        "submit",
        "urgent"
    ]

    static func supportsSuggestions(for date: Date, now: Date = .now) -> Bool {
        DateKeys.startOfDay(date) == DateKeys.startOfDay(now)
    }

    static func nextSuggestion(
        for date: Date,
        in context: ModelContext,
        now: Date = .now
    ) throws -> SuggestedChecklistItem? {
        guard supportsSuggestions(for: date, now: now) else { return nil }

        let yesterday = DateKeys.yesterday(from: now)
        let end = DateKeys.dayAfter(yesterday)
        let events = try ContentIngestionService.fetchEvents(
            from: yesterday,
            until: end,
            in: context
        )
        guard !events.isEmpty else { return nil }

        let decidedKeys = Set(
            try context.fetch(FetchDescriptor<ContentSuggestionDecision>())
                .map(\.eventKey)
        )
        let checklistTitles = try normalizedChecklistTitles(for: date, in: context)
        let sourceCounts = Dictionary(grouping: events, by: \.sourceIdentifier).mapValues(\.count)

        return events
            .compactMap { event -> SuggestedChecklistItem? in
                let eventKey = eventKey(for: event)
                let normalizedEventTitle = normalizedTitle(event.title)
                guard !decidedKeys.contains(eventKey),
                      !normalizedEventTitle.isEmpty,
                      !checklistTitles.contains(normalizedEventTitle)
                else {
                    return nil
                }

                let sourceCount = sourceCounts[event.sourceIdentifier] ?? 1
                let score = score(for: event, sourceEventCount: sourceCount, dayStart: yesterday)
                guard score >= minimumScore else { return nil }

                return SuggestedChecklistItem(
                    eventKey: eventKey,
                    externalID: event.externalID,
                    title: event.title.trimmingCharacters(in: .whitespacesAndNewlines),
                    excerpt: collapsedText(event.body, limit: 180),
                    sourceName: event.sourceName,
                    category: event.category,
                    url: allowedURL(from: event.urlString),
                    receivedAt: event.receivedAt,
                    score: score,
                    reason: reason(for: event, sourceEventCount: sourceCount, dayStart: yesterday)
                )
            }
            .sorted(by: suggestionSort)
            .first
    }

    @discardableResult
    static func accept(
        _ suggestion: SuggestedChecklistItem,
        for date: Date,
        in context: ModelContext,
        now: Date = .now
    ) throws -> DailyChecklistItem? {
        guard supportsSuggestions(for: date, now: now) else { return nil }
        if let decision = try decision(for: suggestion.eventKey, in: context) {
            return try checklistItem(for: decision.checklistItemID, in: context)
        }

        let checklist = try ChecklistStore.checklist(for: date, in: context)
        guard let checklist else { return nil }

        let normalizedSuggestionTitle = normalizedTitle(suggestion.title)
        let existingItem = checklist.items.first {
            normalizedTitle($0.title) == normalizedSuggestionTitle
        }
        let checklistItem = existingItem ?? ChecklistStore.insertItem(
            title: suggestion.title,
            notes: notes(for: suggestion),
            to: checklist,
            in: context
        )
        let decision = ContentSuggestionDecision(
            eventKey: suggestion.eventKey,
            status: .accepted,
            decidedAt: now,
            checklistItemID: checklistItem.id
        )
        context.insert(decision)

        do {
            try context.save()
        } catch {
            context.rollback()
            throw error
        }

        WidgetChecklistSync.publish(checklist)
        return checklistItem
    }

    static func dismiss(
        _ suggestion: SuggestedChecklistItem,
        in context: ModelContext,
        now: Date = .now
    ) throws {
        guard try decision(for: suggestion.eventKey, in: context) == nil else { return }

        context.insert(ContentSuggestionDecision(
            eventKey: suggestion.eventKey,
            status: .dismissed,
            decidedAt: now
        ))

        do {
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }

    static func eventKey(for event: ContentEvent) -> String {
        ContentSuggestionDecision.eventKey(
            sourceIdentifier: event.sourceIdentifier,
            externalID: event.externalID
        )
    }

    static func score(
        for event: ContentEvent,
        sourceEventCount: Int,
        dayStart: Date
    ) -> Int {
        categoryPoints(for: event.category)
            + actionPoints(for: event)
            + recencyPoints(for: event.receivedAt, dayStart: dayStart)
            + sourceActivityPoints(for: sourceEventCount)
    }

    static func normalizedTitle(_ title: String) -> String {
        title
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    static func notes(for suggestion: SuggestedChecklistItem) -> String {
        var sections = ["Suggested from \(suggestion.sourceName) (\(suggestion.category.displayName))"]

        let body = collapsedText(suggestion.excerpt, limit: 500)
        if !body.isEmpty {
            sections.append(body)
        }
        if let url = suggestion.url {
            sections.append(url.absoluteString)
        }

        return sections.joined(separator: "\n\n")
    }

    private static func normalizedChecklistTitles(
        for date: Date,
        in context: ModelContext
    ) throws -> Set<String> {
        guard let checklist = try ChecklistStore.checklist(
            for: date,
            in: context,
            createIfMissing: false
        ) else {
            return []
        }
        return Set(checklist.items.map { normalizedTitle($0.title) })
    }

    private static func decision(
        for eventKey: String,
        in context: ModelContext
    ) throws -> ContentSuggestionDecision? {
        var descriptor = FetchDescriptor<ContentSuggestionDecision>(
            predicate: #Predicate { decision in
                decision.eventKey == eventKey
            }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private static func checklistItem(
        for itemID: UUID?,
        in context: ModelContext
    ) throws -> DailyChecklistItem? {
        guard let itemID else { return nil }
        var descriptor = FetchDescriptor<DailyChecklistItem>(
            predicate: #Predicate { item in
                item.id == itemID
            }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private static func suggestionSort(
        _ left: SuggestedChecklistItem,
        _ right: SuggestedChecklistItem
    ) -> Bool {
        if left.score != right.score {
            return left.score > right.score
        }
        if left.receivedAt != right.receivedAt {
            return left.receivedAt > right.receivedAt
        }
        if left.sourceName != right.sourceName {
            return left.sourceName < right.sourceName
        }
        if left.externalID != right.externalID {
            return left.externalID < right.externalID
        }
        return left.eventKey < right.eventKey
    }

    private static func reason(
        for event: ContentEvent,
        sourceEventCount: Int,
        dayStart: Date
    ) -> String {
        let actionScore = actionPoints(for: event)
        let categoryScore = categoryPoints(for: event.category)
        let recencyScore = recencyPoints(for: event.receivedAt, dayStart: dayStart)
        let sourceScore = sourceActivityPoints(for: sourceEventCount)

        let contributors: [(points: Int, priority: Int, reason: String)] = [
            (categoryScore, 0, categoryReason(for: event.category)),
            (actionScore, 1, "Action-oriented wording suggests a follow-up"),
            (recencyScore, 2, "One of yesterday's most recent items"),
            (sourceScore, 3, "Repeated activity from \(event.sourceName)")
        ]

        return contributors
            .filter { $0.points > 0 && !$0.reason.isEmpty }
            .sorted {
                if $0.points == $1.points { return $0.priority < $1.priority }
                return $0.points > $1.points
            }
            .first?
            .reason ?? "Potential follow-up from yesterday"
    }

    private static func categoryPoints(for category: ContentCategory) -> Int {
        switch category {
        case .task: 60
        case .calendar: 45
        case .message, .alert: 25
        case .article: 5
        case .other: 0
        }
    }

    private static func categoryReason(for category: ContentCategory) -> String {
        switch category {
        case .task: "Task item from yesterday"
        case .calendar: "Calendar item from yesterday"
        case .message: "Message that may need a follow-up"
        case .alert: "Alert that may need attention"
        case .article: "Article that may need a follow-up"
        case .other: ""
        }
    }

    private static func actionPoints(for event: ContentEvent) -> Int {
        let text = " \(normalizedTitle(collapsedText("\(event.title) \(event.body)", limit: 2_000))) "
        let keywords = Set(actionKeywords.map { normalizedTitle($0) })
        let matches = keywords.filter { text.contains(" \($0) ") }.count
        return min(matches, 3) * 12
    }

    private static func recencyPoints(for receivedAt: Date, dayStart: Date) -> Int {
        let dayEnd = DateKeys.dayAfter(dayStart)
        let duration = dayEnd.timeIntervalSince(dayStart)
        guard duration > 0 else { return 0 }
        let fraction = (receivedAt.timeIntervalSince(dayStart) / duration).clamped(to: 0...1)
        return Int((fraction * 10).rounded())
    }

    private static func sourceActivityPoints(for sourceEventCount: Int) -> Int {
        min(max(sourceEventCount - 1, 0) * 2, 6)
    }

    private static func allowedURL(from value: String?) -> URL? {
        guard let value, let url = URL(string: value), FeedURLPolicy.isAllowed(url) else {
            return nil
        }
        return url
    }

    private static func collapsedText(_ value: String, limit: Int) -> String {
        let collapsed = value.replacingOccurrences(
            of: "\\s+",
            with: " ",
            options: .regularExpression
        )
        return String(collapsed.trimmingCharacters(in: .whitespacesAndNewlines).prefix(limit))
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
