import SwiftData
import XCTest
@testable import DayPlan

@MainActor
final class DailyDigestBuilderTests: XCTestCase {
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

    func testDeterministicSummaryGroupsSourceAndCategory() throws {
        let date = Calendar.current.date(from: DateComponents(year: 2026, month: 6, day: 3, hour: 9))!
        let source = ContentSource(identifier: "sample.local", name: "Sample Inbox")
        context.insert(source)
        context.insert(ContentEvent(
            externalID: "one",
            sourceIdentifier: source.identifier,
            sourceName: source.name,
            receivedAt: date,
            title: "First",
            body: "Body",
            category: .task,
            source: source
        ))
        context.insert(ContentEvent(
            externalID: "two",
            sourceIdentifier: source.identifier,
            sourceName: source.name,
            receivedAt: date.addingTimeInterval(120),
            title: "Second",
            body: "Body",
            category: .task,
            source: source
        ))
        try context.save()

        let digest = try DailyDigestBuilder.digest(for: date, in: context)

        XCTAssertTrue(digest.summary.contains("2 item(s)"))
        XCTAssertTrue(digest.summary.contains("Sample Inbox"))
        XCTAssertTrue(digest.summary.contains("Tasks"))
        XCTAssertTrue(digest.summary.contains("Most recent: Second"))
    }

    func testSampleIngestionDoesNotDuplicateEvents() async throws {
        try await ContentIngestionService.ingestYesterdaySampleIfNeeded(in: context)
        try await ContentIngestionService.ingestYesterdaySampleIfNeeded(in: context)

        let yesterday = DateKeys.yesterday()
        let events = try ContentIngestionService.fetchEvents(
            from: yesterday,
            until: DateKeys.dayAfter(yesterday),
            in: context
        )

        XCTAssertEqual(events.count, 3)
    }
}
