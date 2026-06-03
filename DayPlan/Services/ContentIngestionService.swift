import Foundation
import SwiftData

@MainActor
enum ContentIngestionService {
    static func ingestYesterdaySampleIfNeeded(in context: ModelContext, now: Date = .now) async throws {
        let day = DateKeys.yesterday(from: now)
        let end = DateKeys.dayAfter(day)
        let existing = try fetchEvents(from: day, until: end, in: context)

        guard existing.isEmpty else { return }

        try await ingest(
            from: [SampleContentAdapter()],
            since: day,
            until: end,
            in: context
        )
    }

    static func ingest(
        from adapters: [ContentSourceAdapter],
        since startDate: Date,
        until endDate: Date,
        in context: ModelContext
    ) async throws {
        for adapter in adapters {
            let source = try sourceForAdapter(adapter, in: context)
            guard source.isEnabled else { continue }

            let drafts = try await adapter.fetchContent(since: startDate, until: endDate)
            for draft in drafts {
                guard try existingEvent(externalID: draft.id, in: context) == nil else { continue }

                let event = ContentEvent(
                    externalID: draft.id,
                    sourceIdentifier: draft.sourceIdentifier,
                    sourceName: draft.sourceName,
                    receivedAt: draft.receivedAt,
                    title: draft.title,
                    body: draft.body,
                    urlString: draft.url?.absoluteString,
                    category: draft.category,
                    source: source
                )
                source.events.append(event)
                context.insert(event)
            }
        }

        try context.save()
    }

    static func fetchEvents(
        from startDate: Date,
        until endDate: Date,
        in context: ModelContext
    ) throws -> [ContentEvent] {
        let descriptor = FetchDescriptor<ContentEvent>(
            predicate: #Predicate { event in
                event.receivedAt >= startDate && event.receivedAt < endDate
            },
            sortBy: [
                SortDescriptor(\.receivedAt, order: .reverse)
            ]
        )
        return try context.fetch(descriptor)
    }

    private static func sourceForAdapter(
        _ adapter: ContentSourceAdapter,
        in context: ModelContext
    ) throws -> ContentSource {
        let identifier = adapter.identifier
        var descriptor = FetchDescriptor<ContentSource>(
            predicate: #Predicate { source in
                source.identifier == identifier
            }
        )
        descriptor.fetchLimit = 1

        if let existing = try context.fetch(descriptor).first {
            existing.name = adapter.displayName
            existing.updatedAt = .now
            return existing
        }

        let source = ContentSource(identifier: adapter.identifier, name: adapter.displayName)
        context.insert(source)
        return source
    }

    private static func existingEvent(
        externalID: String,
        in context: ModelContext
    ) throws -> ContentEvent? {
        var descriptor = FetchDescriptor<ContentEvent>(
            predicate: #Predicate { event in
                event.externalID == externalID
            }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }
}
