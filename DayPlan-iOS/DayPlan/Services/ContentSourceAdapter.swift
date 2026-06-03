import Foundation

struct ContentEventDraft: Identifiable, Equatable {
    let id: String
    let sourceIdentifier: String
    let sourceName: String
    let receivedAt: Date
    let title: String
    let body: String
    let url: URL?
    let category: ContentCategory
}

protocol ContentSourceAdapter {
    var identifier: String { get }
    var displayName: String { get }
    func fetchContent(since startDate: Date, until endDate: Date) async throws -> [ContentEventDraft]
}

struct SampleContentAdapter: ContentSourceAdapter {
    let identifier = "sample.local"
    let displayName = "Sample Inbox"

    func fetchContent(since startDate: Date, until endDate: Date) async throws -> [ContentEventDraft] {
        let calendar = Calendar.current
        let base = DateKeys.startOfDay(startDate, calendar: calendar)

        let drafts = [
            draft(
                suffix: "morning-brief",
                offsetHour: 8,
                title: "Morning brief",
                body: "Three calendar nudges and one reading reminder were captured for review.",
                category: .calendar,
                base: base,
                calendar: calendar
            ),
            draft(
                suffix: "focus-followup",
                offsetHour: 13,
                title: "Focus follow-up",
                body: "A project note and two task prompts were grouped as afternoon follow-ups.",
                category: .task,
                base: base,
                calendar: calendar
            ),
            draft(
                suffix: "evening-reading",
                offsetHour: 19,
                title: "Evening reading queue",
                body: "Two saved links looked relevant to planning and one was tagged for later.",
                category: .article,
                base: base,
                calendar: calendar
            )
        ]

        return drafts.filter { $0.receivedAt >= startDate && $0.receivedAt < endDate }
    }

    private func draft(
        suffix: String,
        offsetHour: Int,
        title: String,
        body: String,
        category: ContentCategory,
        base: Date,
        calendar: Calendar
    ) -> ContentEventDraft {
        let receivedAt = calendar.date(byAdding: .hour, value: offsetHour, to: base) ?? base
        return ContentEventDraft(
            id: "\(identifier).\(DateKeys.dayKey(for: base)).\(suffix)",
            sourceIdentifier: identifier,
            sourceName: displayName,
            receivedAt: receivedAt,
            title: title,
            body: body,
            url: nil,
            category: category
        )
    }
}
