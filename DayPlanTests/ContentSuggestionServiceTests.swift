import Foundation
import SwiftData
import XCTest
@testable import DayPlan

@MainActor
final class ContentSuggestionServiceTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!
    private var now: Date!
    private var yesterday: Date!

    override func setUpWithError() throws {
        container = try ModelContainerFactory.inMemory()
        context = ModelContext(container)
        now = try XCTUnwrap(Calendar.current.date(
            from: DateComponents(year: 2026, month: 6, day: 4, hour: 12)
        ))
        yesterday = DateKeys.yesterday(from: now)
    }

    override func tearDownWithError() throws {
        yesterday = nil
        now = nil
        context = nil
        container = nil
    }

    func testScoringUsesFixedCategoryKeywordRecencyAndSourceWeights() {
        let task = event(
            id: "task",
            receivedAt: yesterday,
            title: "Plain task",
            category: .task
        )
        XCTAssertEqual(
            ContentSuggestionService.score(for: task, sourceEventCount: 1, dayStart: yesterday),
            60
        )

        let keywordCap = event(
            id: "keywords",
            receivedAt: yesterday,
            title: "Call email submit and review",
            category: .message
        )
        XCTAssertEqual(
            ContentSuggestionService.score(for: keywordCap, sourceEventCount: 1, dayStart: yesterday),
            61
        )

        let lateRepeatedItem = event(
            id: "late",
            receivedAt: DateKeys.dayAfter(yesterday).addingTimeInterval(-1),
            title: "Plain item",
            category: .other
        )
        XCTAssertEqual(
            ContentSuggestionService.score(
                for: lateRepeatedItem,
                sourceEventCount: 5,
                dayStart: yesterday
            ),
            16
        )

        let substringOnly = event(
            id: "substring",
            receivedAt: yesterday,
            title: "Recall notes",
            category: .other
        )
        XCTAssertEqual(
            ContentSuggestionService.score(
                for: substringOnly,
                sourceEventCount: 1,
                dayStart: yesterday
            ),
            0
        )
    }

    func testThresholdAndDeterministicTieBreaking() throws {
        context.insert(event(
            id: "low",
            receivedAt: yesterday.addingTimeInterval(80_000),
            title: "Interesting article",
            category: .article
        ))
        context.insert(event(
            id: "b",
            sourceName: "Inbox",
            receivedAt: yesterday.addingTimeInterval(3_600),
            title: "Task B",
            category: .task
        ))
        context.insert(event(
            id: "a",
            sourceName: "Inbox",
            receivedAt: yesterday.addingTimeInterval(3_600),
            title: "Task A",
            category: .task
        ))
        try context.save()

        let suggestion = try XCTUnwrap(
            ContentSuggestionService.nextSuggestion(for: now, in: context, now: now)
        )

        XCTAssertEqual(suggestion.externalID, "a")
        XCTAssertGreaterThanOrEqual(suggestion.score, ContentSuggestionService.minimumScore)
    }

    func testDecisionsDuplicatesLowScoresAndBlankTitlesAreExcluded() throws {
        let decided = event(
            id: "decided",
            receivedAt: yesterday.addingTimeInterval(3_000),
            title: "Already decided",
            category: .task
        )
        let duplicate = event(
            id: "duplicate",
            receivedAt: yesterday.addingTimeInterval(4_000),
            title: "Review cafe notes!",
            category: .task
        )
        let eligible = event(
            id: "eligible",
            receivedAt: yesterday.addingTimeInterval(2_000),
            title: "Tomorrow's appointment",
            category: .calendar
        )
        context.insert(decided)
        context.insert(duplicate)
        context.insert(eligible)
        context.insert(event(
            id: "low",
            receivedAt: yesterday.addingTimeInterval(70_000),
            title: "News",
            category: .article
        ))
        context.insert(event(
            id: "blank",
            receivedAt: yesterday.addingTimeInterval(80_000),
            title: "  ",
            category: .task
        ))
        context.insert(ContentSuggestionDecision(
            eventKey: ContentSuggestionService.eventKey(for: decided),
            status: .dismissed,
            decidedAt: now
        ))

        let checklist = try XCTUnwrap(ChecklistStore.checklist(for: now, in: context))
        _ = try ChecklistStore.addItem(title: "REVIEW CAFE NOTES", to: checklist, in: context)
        try context.save()

        let suggestion = try XCTUnwrap(
            ContentSuggestionService.nextSuggestion(for: now, in: context, now: now)
        )

        XCTAssertEqual(suggestion.externalID, "eligible")
    }

    func testDismissalSurvivesEventDeletionAndRecreation() throws {
        let original = event(
            id: "stable-event",
            receivedAt: yesterday.addingTimeInterval(1_000),
            title: "Urgent: reply to the message",
            category: .message
        )
        context.insert(original)
        try context.save()

        let suggestion = try XCTUnwrap(
            ContentSuggestionService.nextSuggestion(for: now, in: context, now: now)
        )
        try ContentSuggestionService.dismiss(suggestion, in: context, now: now)
        try ContentSuggestionService.dismiss(suggestion, in: context, now: now)
        XCTAssertEqual(
            try context.fetch(FetchDescriptor<ContentSuggestionDecision>()).count,
            1
        )

        context.delete(original)
        try context.save()
        context.insert(event(
            id: "stable-event",
            receivedAt: yesterday.addingTimeInterval(2_000),
            title: "Urgent: reply to the updated message",
            category: .message
        ))
        try context.save()

        XCTAssertNil(try ContentSuggestionService.nextSuggestion(for: now, in: context, now: now))
    }

    func testAcceptanceCreatesOneContextualNonPersistentTaskAndOneDecision() throws {
        context.insert(event(
            id: "accept",
            sourceName: "Work Inbox",
            receivedAt: yesterday.addingTimeInterval(8_000),
            title: "Submit expense report",
            body: "The report is due before Friday.",
            urlString: "https://example.com/report",
            category: .task
        ))
        try context.save()

        let suggestion = try XCTUnwrap(
            ContentSuggestionService.nextSuggestion(for: now, in: context, now: now)
        )
        let first = try XCTUnwrap(
            ContentSuggestionService.accept(suggestion, for: now, in: context, now: now)
        )
        let second = try XCTUnwrap(
            ContentSuggestionService.accept(suggestion, for: now, in: context, now: now)
        )

        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(first.title, "Submit expense report")
        XCTAssertFalse(first.isPersistent)
        XCTAssertTrue(first.reminders.isEmpty)
        XCTAssertTrue(first.notes.contains("Work Inbox"))
        XCTAssertTrue(first.notes.contains("The report is due before Friday."))
        XCTAssertTrue(first.notes.contains("https://example.com/report"))

        let items = try context.fetch(FetchDescriptor<DailyChecklistItem>())
        let decisions = try context.fetch(FetchDescriptor<ContentSuggestionDecision>())
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(decisions.count, 1)
        XCTAssertEqual(decisions.first?.status, .accepted)
        XCTAssertEqual(decisions.first?.checklistItemID, first.id)
        XCTAssertNil(try ContentSuggestionService.nextSuggestion(for: now, in: context, now: now))
    }

    func testSuggestionOnlyIncludesValidatedPublicHTTPSURL() throws {
        context.insert(event(
            id: "unsafe-url",
            receivedAt: yesterday.addingTimeInterval(1_000),
            title: "Review private dashboard",
            urlString: "http://localhost/dashboard",
            category: .task
        ))
        try context.save()

        let suggestion = try XCTUnwrap(
            ContentSuggestionService.nextSuggestion(for: now, in: context, now: now)
        )

        XCTAssertNil(suggestion.url)
        XCTAssertFalse(ContentSuggestionService.notes(for: suggestion).contains("localhost"))
    }

    func testDismissAdvancesUntilSuggestionsAreExhausted() throws {
        context.insert(event(
            id: "older",
            receivedAt: yesterday.addingTimeInterval(1_000),
            title: "Older task",
            category: .task
        ))
        context.insert(event(
            id: "newer",
            receivedAt: yesterday.addingTimeInterval(2_000),
            title: "Newer task",
            category: .task
        ))
        try context.save()

        let first = try XCTUnwrap(
            ContentSuggestionService.nextSuggestion(for: now, in: context, now: now)
        )
        XCTAssertEqual(first.externalID, "newer")
        try ContentSuggestionService.dismiss(first, in: context, now: now)

        let second = try XCTUnwrap(
            ContentSuggestionService.nextSuggestion(for: now, in: context, now: now)
        )
        XCTAssertEqual(second.externalID, "older")
        try ContentSuggestionService.dismiss(second, in: context, now: now)

        XCTAssertNil(try ContentSuggestionService.nextSuggestion(for: now, in: context, now: now))
    }

    func testSuggestionsAreSupportedOnlyForToday() throws {
        context.insert(event(
            id: "task",
            receivedAt: yesterday.addingTimeInterval(1_000),
            title: "Follow up",
            category: .task
        ))
        try context.save()

        XCTAssertTrue(ContentSuggestionService.supportsSuggestions(for: now, now: now))
        XCTAssertFalse(ContentSuggestionService.supportsSuggestions(
            for: DateKeys.dayAfter(now),
            now: now
        ))
        XCTAssertNil(try ContentSuggestionService.nextSuggestion(
            for: DateKeys.dayAfter(now),
            in: context,
            now: now
        ))
    }

    func testAddingSuggestionModelOpensExistingStore() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DayPlanSuggestionMigration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("DayPlan.store")

        try createLegacyStore(at: storeURL)

        let schema = Schema(DayPlanSchema.models)
        let configuration = ModelConfiguration(
            "DayPlanMigration",
            schema: schema,
            url: storeURL,
            cloudKitDatabase: .none
        )
        let migratedContainer = try ModelContainer(
            for: schema,
            configurations: [configuration]
        )
        let migratedContext = ModelContext(migratedContainer)

        XCTAssertEqual(try migratedContext.fetch(FetchDescriptor<DailyContentDigest>()).count, 1)
        migratedContext.insert(ContentSuggestionDecision(
            eventKey: "migration-event",
            status: .dismissed
        ))
        try migratedContext.save()
        XCTAssertEqual(
            try migratedContext.fetch(FetchDescriptor<ContentSuggestionDecision>()).count,
            1
        )
    }

    private func event(
        id: String,
        sourceIdentifier: String = "source.test",
        sourceName: String = "Source",
        receivedAt: Date,
        title: String,
        body: String = "",
        urlString: String? = nil,
        category: ContentCategory
    ) -> ContentEvent {
        ContentEvent(
            externalID: id,
            sourceIdentifier: sourceIdentifier,
            sourceName: sourceName,
            receivedAt: receivedAt,
            title: title,
            body: body,
            urlString: urlString,
            category: category
        )
    }

    private func createLegacyStore(at url: URL) throws {
        let schema = Schema(DayPlanSchema.modelsBeforeContentSuggestions)
        let configuration = ModelConfiguration(
            "DayPlanMigration",
            schema: schema,
            url: url,
            cloudKitDatabase: .none
        )
        let legacyContainer = try ModelContainer(
            for: schema,
            configurations: [configuration]
        )
        let legacyContext = ModelContext(legacyContainer)
        legacyContext.insert(DailyContentDigest(
            date: yesterday,
            summary: "Existing local data"
        ))
        try legacyContext.save()
    }
}
