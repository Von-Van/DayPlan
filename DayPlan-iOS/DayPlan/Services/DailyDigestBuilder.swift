import Foundation
import SwiftData

@MainActor
enum DailyDigestBuilder {
    static func digest(for date: Date, in context: ModelContext) throws -> DailyContentDigest {
        let day = DateKeys.startOfDay(date)
        let end = DateKeys.dayAfter(day)
        let events = try ContentIngestionService.fetchEvents(from: day, until: end, in: context)
        let summary = summaryText(for: events, date: day)

        if let existing = try existingDigest(for: day, in: context) {
            existing.summary = summary
            existing.generatedAt = .now
            try context.save()
            return existing
        }

        let digest = DailyContentDigest(date: day, summary: summary)
        context.insert(digest)
        try context.save()
        return digest
    }

    static func summaryText(for events: [ContentEvent], date: Date) -> String {
        guard !events.isEmpty else {
            return "No source items were captured for \(DateKeys.dayKey(for: date))."
        }

        let sourceCounts = Dictionary(grouping: events, by: \.sourceName)
            .mapValues(\.count)
            .sorted { left, right in
                if left.value == right.value { return left.key < right.key }
                return left.value > right.value
            }

        let categoryCounts = Dictionary(grouping: events, by: { $0.category.displayName })
            .mapValues(\.count)
            .sorted { left, right in
                if left.value == right.value { return left.key < right.key }
                return left.value > right.value
            }

        let topSource = sourceCounts.first.map { "\($0.key) was the busiest source with \($0.value) item(s)." }
        let topCategory = categoryCounts.first.map { "\($0.key) was the most common category." }
        let newest = events.sorted { $0.receivedAt > $1.receivedAt }.first
        let newestLine = newest.map { "Most recent: \($0.title)." }

        return [
            "\(events.count) item(s) arrived from \(sourceCounts.count) source(s).",
            topSource,
            topCategory,
            newestLine
        ]
        .compactMap { $0 }
        .joined(separator: " ")
    }

    private static func existingDigest(
        for date: Date,
        in context: ModelContext
    ) throws -> DailyContentDigest? {
        var descriptor = FetchDescriptor<DailyContentDigest>(
            predicate: #Predicate { digest in
                digest.date == date
            }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }
}
