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

    func testIngestionReconcilesItemsWhenSourceFiltersChange() async throws {
        let day = DateKeys.yesterday()
        let end = DateKeys.dayAfter(day)
        let first = ContentEventDraft(
            id: "first",
            sourceIdentifier: "rss.test",
            sourceName: "Test Feed",
            receivedAt: day.addingTimeInterval(3_600),
            title: "First",
            body: "Keep",
            url: nil,
            category: .article
        )
        let second = ContentEventDraft(
            id: "second",
            sourceIdentifier: "rss.test",
            sourceName: "Test Feed",
            receivedAt: day.addingTimeInterval(7_200),
            title: "Second",
            body: "Remove after filter change",
            url: nil,
            category: .article
        )

        _ = try await ContentIngestionService.ingest(
            from: [StaticContentAdapter(drafts: [first, second])],
            since: day,
            until: end,
            in: context
        )
        _ = try await ContentIngestionService.ingest(
            from: [StaticContentAdapter(drafts: [first])],
            since: day,
            until: end,
            in: context
        )

        let events = try ContentIngestionService.fetchEvents(from: day, until: end, in: context)
        XCTAssertEqual(events.map(\.externalID), ["first"])
    }
}

final class FeedSourceTests: XCTestCase {
    func testFeedURLPolicyAcceptsPublicHTTPSAndRejectsUnsafeURLs() throws {
        let valid = try FeedURLPolicy.validatedPublicHTTPSURL(from: "https://example.com/feed.xml#latest")
        XCTAssertEqual(valid.absoluteString, "https://example.com/feed.xml")

        XCTAssertThrowsError(try FeedURLPolicy.validatedPublicHTTPSURL(from: "http://example.com/feed.xml")) { error in
            XCTAssertEqual(error as? FeedSourceError, .httpsRequired)
        }
        XCTAssertThrowsError(try FeedURLPolicy.validatedPublicHTTPSURL(from: "https://user:password@example.com/feed.xml")) { error in
            XCTAssertEqual(error as? FeedSourceError, .credentialsNotAllowed)
        }
        XCTAssertThrowsError(try FeedURLPolicy.validatedPublicHTTPSURL(from: "https://localhost/feed.xml")) { error in
            XCTAssertEqual(error as? FeedSourceError, .localAddressNotAllowed)
        }
        XCTAssertThrowsError(try FeedURLPolicy.validatedPublicHTTPSURL(from: "https://192.168.1.2/feed.xml")) { error in
            XCTAssertEqual(error as? FeedSourceError, .localAddressNotAllowed)
        }
    }

    func testRSSParserSanitizesAndAppliesKeywordFilters() throws {
        let startDate = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-06-03T00:00:00Z"))
        let endDate = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-06-04T00:00:00Z"))
        let endpoint = try FeedURLPolicy.validatedPublicHTTPSURL(from: "https://example.com/feed.xml")
        let configuration = FeedSourceConfiguration(
            identifier: "rss.test",
            displayName: "Test Feed",
            endpointURL: endpoint,
            includeKeywords: ["swift"],
            excludeKeywords: ["sponsored"],
            maxItems: 10
        )
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0">
          <channel>
            <title>Test Feed</title>
            <item>
              <guid>keep</guid>
              <title>Swift release</title>
              <description><![CDATA[<p>A useful &amp; concise update.</p>]]></description>
              <link>https://example.com/keep</link>
              <pubDate>Wed, 03 Jun 2026 12:00:00 +0000</pubDate>
            </item>
            <item>
              <guid>exclude</guid>
              <title>Sponsored Swift course</title>
              <description>Promotion</description>
              <pubDate>Wed, 03 Jun 2026 13:00:00 +0000</pubDate>
            </item>
            <item>
              <guid>outside</guid>
              <title>Swift from another day</title>
              <description>Old item</description>
              <pubDate>Tue, 02 Jun 2026 13:00:00 +0000</pubDate>
            </item>
          </channel>
        </rss>
        """

        let drafts = try RSSAtomFeedParser.parse(
            data: Data(xml.utf8),
            configuration: configuration,
            since: startDate,
            until: endDate
        )

        XCTAssertEqual(drafts.count, 1)
        XCTAssertEqual(drafts.first?.title, "Swift release")
        XCTAssertEqual(drafts.first?.body, "A useful & concise update.")
        XCTAssertEqual(drafts.first?.url?.absoluteString, "https://example.com/keep")
    }

    func testContentSourceStoresCustomization() {
        let source = ContentSource(
            identifier: "rss.test",
            name: "Test",
            kind: .rss,
            endpointURLString: "https://example.com/feed.xml",
            defaultCategory: .message,
            includeKeywords: ["Swift", "iOS"],
            excludeKeywords: ["Sponsored"],
            maxItemsPerRefresh: 25
        )

        XCTAssertEqual(source.kind, .rss)
        XCTAssertEqual(source.defaultCategory, .message)
        XCTAssertEqual(source.includeKeywords, ["Swift", "iOS"])
        XCTAssertEqual(source.excludeKeywords, ["Sponsored"])
        XCTAssertEqual(source.maxItemsPerRefresh, 25)
    }
}

private struct StaticContentAdapter: ContentSourceAdapter {
    let identifier = "rss.test"
    let displayName = "Test Feed"
    let drafts: [ContentEventDraft]

    func fetchContent(since startDate: Date, until endDate: Date) async throws -> [ContentEventDraft] {
        drafts.filter { $0.receivedAt >= startDate && $0.receivedAt < endDate }
    }
}
