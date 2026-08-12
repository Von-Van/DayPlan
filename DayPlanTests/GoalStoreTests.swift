import SwiftData
import XCTest
@testable import DayPlan

@MainActor
final class GoalStoreTests: XCTestCase {
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

    func testCreateArchiveLinkAndProgress() throws {
        let goal = try GoalStore.createGoal(
            title: "Ship Mac app",
            details: "Native desktop build",
            colorName: "blue",
            targetDate: date,
            in: context
        )
        let completedAction = try GoalStore.addAction(title: "Draft layout", to: goal, in: context)
        _ = try GoalStore.addAction(title: "Polish details", to: goal, in: context)
        try GoalStore.setActionCompletion(completedAction, isCompleted: true, in: context)

        let checklist = try XCTUnwrap(ChecklistStore.checklist(for: date, in: context))
        let dailyItem = try ChecklistStore.addItem(title: "Review build", to: checklist, in: context)
        try GoalStore.link(dailyItem, to: goal, in: context)
        try ChecklistStore.toggleCompletion(for: dailyItem, isCompleted: true, in: context)

        let collection = CollectionList(name: "Launch")
        let collectionItem = CollectionItem(title: "Announcement", collection: collection)
        collection.items.append(collectionItem)
        context.insert(collection)
        context.insert(collectionItem)
        try context.save()
        try GoalStore.link(collectionItem, to: goal, in: context)

        let progress = try GoalStore.progress(for: goal, in: context)
        XCTAssertEqual(progress.completed, 2)
        XCTAssertEqual(progress.total, 4)
        XCTAssertEqual(progress.percentage, 50)

        XCTAssertEqual(try GoalStore.activeGoals(in: context).map(\.title), ["Ship Mac app"])
        try GoalStore.archive(goal, at: date, in: context)
        XCTAssertTrue(try GoalStore.activeGoals(in: context).isEmpty)
    }

    func testSchedulingActionCreatesSingleLinkedDailyItemAndMirrorsCompletion() throws {
        let goal = try GoalStore.createGoal(title: "Write", in: context)
        let action = try GoalStore.addAction(
            title: "Outline chapter",
            notes: "Keep it tight",
            priority: .high,
            to: goal,
            in: context
        )

        let item = try GoalStore.schedule(action, for: date, in: context)

        XCTAssertEqual(item.title, "Outline chapter")
        XCTAssertEqual(item.notes, "Keep it tight")
        XCTAssertEqual(item.goalID, goal.id)
        XCTAssertEqual(item.goalActionID, action.id)
        XCTAssertFalse(item.isPersistent)
        XCTAssertEqual(action.scheduledChecklistItemID, item.id)
        XCTAssertEqual(action.scheduledDate, date)

        var progress = try GoalStore.progress(for: goal, in: context)
        XCTAssertEqual(progress.completed, 0)
        XCTAssertEqual(progress.total, 1)

        try ChecklistStore.toggleCompletion(for: item, isCompleted: true, in: context)
        XCTAssertTrue(action.isCompleted)
        XCTAssertNotNil(action.completedAt)

        progress = try GoalStore.progress(for: goal, in: context)
        XCTAssertEqual(progress.completed, 1)
        XCTAssertEqual(progress.total, 1)

        try GoalStore.setActionCompletion(action, isCompleted: false, in: context)
        XCTAssertFalse(item.isCompleted)
        XCTAssertNil(item.completedAt)
    }

    func testDeletingScheduledDailyItemClearsScheduleButKeepsAction() throws {
        let goal = try GoalStore.createGoal(title: "Prepare demo", in: context)
        let action = try GoalStore.addAction(title: "Record clip", to: goal, in: context)
        let item = try GoalStore.schedule(action, for: date, in: context)

        try ChecklistStore.deleteItem(item, in: context)

        XCTAssertNil(action.scheduledDate)
        XCTAssertNil(action.scheduledChecklistItemID)
        XCTAssertEqual(goal.actions.map(\.title), ["Record clip"])
    }
}
