import SwiftData
import XCTest
@testable import DayPlan

@MainActor
final class CompletionStatsServiceTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!
    private var today: Date!

    override func setUpWithError() throws {
        container = try ModelContainerFactory.inMemory()
        context = ModelContext(container)
        today = DateKeys.startOfDay(Calendar.current.date(
            from: DateComponents(year: 2026, month: 6, day: 23)
        )!)
    }

    override func tearDownWithError() throws {
        today = nil
        context = nil
        container = nil
    }

    func testSummaryCalculatesDailyWindowsStreaksAndCollections() throws {
        try insertChecklist(dayOffset: -3, completed: 1, total: 1)
        try insertChecklist(dayOffset: -2, completed: 1, total: 1)
        try insertChecklist(dayOffset: -1, completed: 2, total: 2)
        try insertChecklist(dayOffset: 0, completed: 1, total: 2)
        try insertChecklist(dayOffset: -10, completed: 1, total: 1)

        let collection = CollectionList(name: "Projects")
        let first = CollectionItem(title: "One", isCompleted: true, collection: collection)
        let second = CollectionItem(title: "Two", collection: collection)
        collection.items.append(first)
        collection.items.append(second)
        context.insert(collection)
        context.insert(first)
        context.insert(second)
        try context.save()

        let summary = try CompletionStatsService.summary(in: context, now: today)

        XCTAssertEqual(summary.today, CompletionStatsMetric(completed: 1, total: 2))
        XCTAssertEqual(summary.lastSevenDays, CompletionStatsMetric(completed: 5, total: 6))
        XCTAssertEqual(summary.lastThirtyDays, CompletionStatsMetric(completed: 6, total: 7))
        XCTAssertEqual(summary.allTimeDaily, CompletionStatsMetric(completed: 6, total: 7))
        XCTAssertEqual(summary.collections, CompletionStatsMetric(completed: 1, total: 2))
        XCTAssertEqual(summary.currentDailyStreak, 0)
        XCTAssertEqual(summary.bestDailyStreak, 3)
        XCTAssertEqual(summary.trackedDayCount, 5)
    }

    func testCurrentStreakCountsThroughTodayWhenTodayIsComplete() throws {
        try insertChecklist(dayOffset: -1, completed: 1, total: 1)
        try insertChecklist(dayOffset: 0, completed: 2, total: 2)

        let summary = try CompletionStatsService.summary(in: context, now: today)

        XCTAssertEqual(summary.currentDailyStreak, 2)
        XCTAssertEqual(summary.bestDailyStreak, 2)
    }

    private func insertChecklist(dayOffset: Int, completed: Int, total: Int) throws {
        let date = Calendar.current.date(byAdding: .day, value: dayOffset, to: today)!
        let checklist = DailyChecklist(date: date)
        context.insert(checklist)

        for index in 0..<total {
            let isCompleted = index < completed
            let item = DailyChecklistItem(
                title: "Task \(dayOffset)-\(index)",
                isCompleted: isCompleted,
                completedAt: isCompleted ? date : nil,
                sortOrder: index,
                checklist: checklist
            )
            checklist.items.append(item)
            context.insert(item)
        }
        try context.save()
    }
}
