import SwiftData
import XCTest
@testable import DayPlan

final class WidgetChecklistStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        suiteName = "dayplan.widget.tests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
    }

    func testToggleUpdatesSnapshotAndQueuesMutation() throws {
        let itemID = UUID()
        let item = WidgetChecklistItem(
            id: itemID,
            title: "Review the day",
            isCompleted: false,
            sortOrder: 0,
            reminderIdentifiers: ["dayplan.reminder"]
        )
        let snapshot = WidgetChecklistSnapshot(
            dayKey: WidgetChecklistStore.dayKey(for: .now),
            generatedAt: .now,
            items: [item]
        )

        XCTAssertTrue(
            WidgetChecklistStore.save(snapshot, defaults: defaults, reloadWidgets: false)
        )

        let mutation = try XCTUnwrap(
            WidgetChecklistStore.toggle(
                itemID: itemID,
                defaults: defaults,
                reloadWidgets: false
            )
        )

        XCTAssertTrue(mutation.isCompleted)
        XCTAssertEqual(mutation.reminderIdentifiers, ["dayplan.reminder"])
        XCTAssertEqual(
            WidgetChecklistStore.snapshot(defaults: defaults)?.items.first?.isCompleted,
            true
        )
        XCTAssertEqual(WidgetChecklistStore.pendingMutations(defaults: defaults), [mutation])

        WidgetChecklistStore.acknowledge(mutationIDs: [mutation.id], defaults: defaults)
        XCTAssertTrue(WidgetChecklistStore.pendingMutations(defaults: defaults).isEmpty)
    }

    func testStaleSnapshotCannotBeToggledOnANewDay() {
        let itemID = UUID()
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: .now)!
        let snapshot = WidgetChecklistSnapshot(
            dayKey: WidgetChecklistStore.dayKey(for: yesterday),
            generatedAt: yesterday,
            items: [
                WidgetChecklistItem(
                    id: itemID,
                    title: "Old task",
                    isCompleted: false,
                    sortOrder: 0,
                    reminderIdentifiers: []
                )
            ]
        )

        XCTAssertTrue(
            WidgetChecklistStore.save(snapshot, defaults: defaults, reloadWidgets: false)
        )
        XCTAssertNil(
            WidgetChecklistStore.toggle(
                itemID: itemID,
                defaults: defaults,
                reloadWidgets: false
            )
        )
        XCTAssertTrue(WidgetChecklistStore.pendingMutations(defaults: defaults).isEmpty)
    }

    func testPendingWidgetMutationReconcilesIntoSwiftData() throws {
        let container = try ModelContainerFactory.inMemory()
        let context = ModelContext(container)
        let checklist = DailyChecklist(date: DateKeys.startOfDay(.now))
        let item = DailyChecklistItem(title: "Finish notes", checklist: checklist)
        checklist.items.append(item)
        context.insert(checklist)
        context.insert(item)
        try context.save()

        WidgetChecklistSync.publish(
            checklist,
            defaults: defaults,
            reloadWidgets: false
        )
        XCTAssertNotNil(
            WidgetChecklistStore.toggle(
                itemID: item.id,
                defaults: defaults,
                reloadWidgets: false
            )
        )

        try WidgetChecklistSync.applyPendingMutations(
            in: context,
            defaults: defaults,
            reloadWidgets: false
        )

        XCTAssertTrue(item.isCompleted)
        XCTAssertNotNil(item.completedAt)
        XCTAssertTrue(WidgetChecklistStore.pendingMutations(defaults: defaults).isEmpty)
    }

    func testMainStoreConfigurationStaysOutsideAppGroupAndCloudKit() {
        let configuration = ModelContainerFactory.privateConfiguration(
            schema: Schema(DayPlanSchema.models)
        )

        XCTAssertNil(configuration.groupAppContainerIdentifier)
        XCTAssertNil(configuration.cloudKitContainerIdentifier)
    }
}
