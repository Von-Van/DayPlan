import SwiftData
import XCTest
@testable import DayPlan

@MainActor
final class DataArchiveServiceTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!
    private var date: Date!

    override func setUpWithError() throws {
        container = try ModelContainerFactory.inMemory()
        context = ModelContext(container)
        date = DateKeys.startOfDay(Calendar.current.date(
            from: DateComponents(year: 2026, month: 6, day: 23)
        )!)
    }

    override func tearDownWithError() throws {
        date = nil
        context = nil
        container = nil
    }

    func testExportAndReplaceRoundTripsLocalData() throws {
        let goal = Goal(
            title: "Ship Mac app",
            details: "Desktop workspace",
            colorName: "purple",
            targetDate: date
        )
        context.insert(goal)

        let template = ChecklistTemplateItem(title: "Stretch", goalID: goal.id, sortOrder: 0)
        context.insert(template)

        let checklist = DailyChecklist(date: date)
        let item = DailyChecklistItem(
            title: "Submit report",
            notes: "Archive me",
            isCompleted: true,
            completedAt: date,
            isPersistent: true,
            templateID: template.id,
            goalID: goal.id,
            sortOrder: 0,
            checklist: checklist
        )
        let action = GoalAction(
            title: "Submit report",
            notes: "Goal action",
            priority: .high,
            isCompleted: true,
            completedAt: date,
            scheduledDate: date,
            scheduledChecklistItemID: item.id,
            goal: goal
        )
        item.goalActionID = action.id
        goal.actions.append(action)
        context.insert(action)

        let reminder = ReminderSchedule(
            itemID: item.id,
            checklistDate: date,
            hour: 9,
            minute: 15
        )
        checklist.items.append(item)
        item.reminders.append(reminder)
        context.insert(checklist)
        context.insert(item)
        context.insert(reminder)

        let collection = CollectionList(name: "Errands")
        let collectionItem = CollectionItem(
            title: "Groceries",
            priority: .high,
            goalID: goal.id,
            collection: collection
        )
        collection.items.append(collectionItem)
        context.insert(collection)
        context.insert(collectionItem)

        let source = ContentSource(
            identifier: "rss.test",
            name: "Test Feed",
            kind: .rss,
            endpointURLString: "https://example.com/feed.xml",
            defaultCategory: .task,
            includeKeywords: ["swift"],
            excludeKeywords: ["sponsored"]
        )
        let event = ContentEvent(
            externalID: "event-1",
            sourceIdentifier: source.identifier,
            sourceName: source.name,
            receivedAt: date,
            title: "Review Swift",
            body: "Body",
            category: .task,
            source: source
        )
        source.events.append(event)
        context.insert(source)
        context.insert(event)
        context.insert(DailyContentDigest(date: date, summary: "Summary"))
        context.insert(ContentSuggestionDecision(
            eventKey: ContentSuggestionDecision.eventKey(
                sourceIdentifier: source.identifier,
                externalID: event.externalID
            ),
            status: .dismissed,
            decidedAt: date
        ))
        context.insert(ContentSuggestionSourceRule(
            sourceIdentifier: source.identifier,
            priority: .high,
            includeKeywords: ["review"]
        ))
        try context.save()

        let archive = try DataArchiveService.exportData(in: context, exportedAt: date)

        context.insert(ChecklistTemplateItem(title: "Temporary"))
        try context.save()

        try DataArchiveService.replaceData(with: archive, in: context)

        let restoredChecklists = try context.fetch(FetchDescriptor<DailyChecklist>())
        let restoredItems = try context.fetch(FetchDescriptor<DailyChecklistItem>())
        let restoredCollections = try context.fetch(FetchDescriptor<CollectionList>())
        let restoredSources = try context.fetch(FetchDescriptor<ContentSource>())
        let restoredEvents = try context.fetch(FetchDescriptor<ContentEvent>())
        let restoredRules = try context.fetch(FetchDescriptor<ContentSuggestionSourceRule>())
        let restoredDecisions = try context.fetch(FetchDescriptor<ContentSuggestionDecision>())
        let restoredGoals = try context.fetch(FetchDescriptor<Goal>())

        XCTAssertEqual(try context.fetch(FetchDescriptor<ChecklistTemplateItem>()).map(\.title), ["Stretch"])
        XCTAssertEqual(try context.fetch(FetchDescriptor<ChecklistTemplateItem>()).first?.goalID, goal.id)
        XCTAssertEqual(restoredChecklists.count, 1)
        XCTAssertEqual(restoredItems.first?.title, "Submit report")
        XCTAssertEqual(restoredItems.first?.goalID, goal.id)
        XCTAssertEqual(restoredItems.first?.goalActionID, action.id)
        XCTAssertEqual(restoredItems.first?.reminders.first?.hour, 9)
        XCTAssertEqual(restoredCollections.first?.items.first?.title, "Groceries")
        XCTAssertEqual(restoredCollections.first?.items.first?.goalID, goal.id)
        XCTAssertEqual(restoredGoals.first?.title, "Ship Mac app")
        XCTAssertEqual(restoredGoals.first?.actions.first?.scheduledChecklistItemID, restoredItems.first?.id)
        XCTAssertEqual(restoredSources.first?.includeKeywords, ["swift"])
        XCTAssertEqual(restoredEvents.first?.title, "Review Swift")
        XCTAssertEqual(restoredRules.first?.priority, .high)
        XCTAssertEqual(restoredDecisions.first?.status, .dismissed)
    }

    func testImportsVersionOneArchiveWithoutGoals() throws {
        let archive = """
        {
          "appName" : "DayPlan",
          "schemaVersion" : 1,
          "exportedAt" : "2026-06-23T00:00:00Z",
          "templates" : [],
          "dailyChecklists" : [],
          "collections" : [],
          "contentSources" : [],
          "contentEvents" : [],
          "contentDigests" : [],
          "suggestionDecisions" : []
        }
        """.data(using: .utf8)!

        try DataArchiveService.replaceData(with: archive, in: context)

        XCTAssertTrue(try context.fetch(FetchDescriptor<Goal>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<DailyChecklist>()).isEmpty)
    }

    func testRejectsUnsupportedArchive() throws {
        let data = Data(#"{"appName":"SomethingElse","schemaVersion":1}"#.utf8)

        XCTAssertThrowsError(try DataArchiveService.replaceData(with: data, in: context)) { error in
            XCTAssertEqual(error as? DataArchiveError, .unsupportedArchive)
        }
    }
}
