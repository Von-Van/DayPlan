import SwiftData
import XCTest
@testable import DayPlan

final class ChecklistStoreTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUpWithError() throws {
        container = try ModelContainerFactory.inMemory()
        context = ModelContext(container)
    }

    override func tearDownWithError() throws {
        context = nil
        container = nil
    }

    func testMaterializesActiveTemplatesOnlyWhenDayIsOpened() throws {
        let template = ChecklistTemplateItem(title: "Stretch", sortOrder: 0)
        context.insert(template)
        try context.save()

        let tomorrow = DateKeys.dayAfter(.now)
        let beforeOpen = try ChecklistStore.checklist(for: tomorrow, in: context, createIfMissing: false)
        XCTAssertNil(beforeOpen)

        let opened = try XCTUnwrap(ChecklistStore.checklist(for: tomorrow, in: context))
        XCTAssertEqual(opened.items.count, 1)
        XCTAssertEqual(opened.items.first?.title, "Stretch")
        XCTAssertEqual(opened.items.first?.templateID, template.id)
    }

    func testPersistentItemCreatesFutureCopyAndPreservesPastCompletion() throws {
        let today = DateKeys.startOfDay(.now)
        let yesterday = DateKeys.yesterday()
        let todayChecklist = try XCTUnwrap(ChecklistStore.checklist(for: today, in: context))
        let todayItem = try ChecklistStore.addItem(title: "Read", to: todayChecklist, in: context)
        try ChecklistStore.setPersistence(for: todayItem, isPersistent: true, in: context)
        try ChecklistStore.toggleCompletion(for: todayItem, isCompleted: true, in: context)

        let pastChecklist = try XCTUnwrap(ChecklistStore.checklist(for: yesterday, in: context))
        let pastItem = try XCTUnwrap(pastChecklist.items.first)
        try ChecklistStore.toggleCompletion(for: pastItem, isCompleted: true, in: context)

        try ChecklistStore.updateItem(todayItem, title: "Read notes", notes: "", in: context)

        XCTAssertEqual(pastItem.title, "Read")
        XCTAssertTrue(pastItem.isCompleted)

        let tomorrow = DateKeys.dayAfter(today)
        let tomorrowChecklist = try XCTUnwrap(ChecklistStore.checklist(for: tomorrow, in: context))
        XCTAssertEqual(tomorrowChecklist.items.first?.title, "Read notes")
        XCTAssertEqual(tomorrowChecklist.items.first?.isCompleted, false)
    }

    func testUnmarkingPersistenceStopsFutureCopies() throws {
        let checklist = try XCTUnwrap(ChecklistStore.checklist(for: .now, in: context))
        let item = try ChecklistStore.addItem(title: "Walk", to: checklist, in: context)

        try ChecklistStore.setPersistence(for: item, isPersistent: true, in: context)
        try ChecklistStore.setPersistence(for: item, isPersistent: false, in: context)

        let tomorrow = try XCTUnwrap(ChecklistStore.checklist(for: DateKeys.dayAfter(.now), in: context))
        XCTAssertTrue(tomorrow.items.isEmpty)
        XCTAssertFalse(item.isPersistent)
    }

    func testReminderIdentifierIsStable() {
        let itemID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let date = Calendar.current.date(from: DateComponents(year: 2026, month: 6, day: 3))!
        let schedule = ReminderSchedule(itemID: itemID, checklistDate: date, hour: 9, minute: 30)

        XCTAssertEqual(
            schedule.notificationIdentifier,
            "dayplan.checklist.2026-06-03.11111111-1111-1111-1111-111111111111.9-30"
        )
    }
}
