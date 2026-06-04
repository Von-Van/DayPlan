import Foundation
import SwiftData

struct ContentRefreshFailure: Equatable {
    let sourceName: String
    let message: String
}

struct ContentRefreshReport: Equatable {
    var importedItemCount = 0
    var refreshedSourceCount = 0
    var failures: [ContentRefreshFailure] = []

    var hasFailures: Bool {
        !failures.isEmpty
    }

    mutating func merge(_ other: ContentRefreshReport) {
        importedItemCount += other.importedItemCount
        refreshedSourceCount += other.refreshedSourceCount
        failures += other.failures
    }
}

@MainActor
enum ContentIngestionService {
    static func refreshYesterday(in context: ModelContext, now: Date = .now) async throws -> ContentRefreshReport {
        let day = DateKeys.yesterday(from: now)
        let end = DateKeys.dayAfter(day)
        var sources = try fetchSources(in: context)

        if sources.isEmpty {
            _ = try sourceForAdapter(SampleContentAdapter(), in: context)
            try context.save()
            sources = try fetchSources(in: context)
        }

        var report = ContentRefreshReport()
        for source in sources where source.isEnabled {
            do {
                let adapter = try adapter(for: source)
                let sourceReport = try await ingest(
                    from: [adapter],
                    since: day,
                    until: end,
                    in: context
                )
                report.merge(sourceReport)
            } catch {
                let message = conciseMessage(for: error)
                source.lastErrorMessage = message
                source.updatedAt = .now
                report.failures.append(ContentRefreshFailure(sourceName: source.name, message: message))
            }
        }

        try context.save()
        return report
    }

    static func ingestYesterdaySampleIfNeeded(in context: ModelContext, now: Date = .now) async throws {
        let day = DateKeys.yesterday(from: now)
        _ = try await ingest(
            from: [SampleContentAdapter()],
            since: day,
            until: DateKeys.dayAfter(day),
            in: context
        )
    }

    static func ingest(
        from adapters: [ContentSourceAdapter],
        since startDate: Date,
        until endDate: Date,
        in context: ModelContext
    ) async throws -> ContentRefreshReport {
        var report = ContentRefreshReport()

        for adapter in adapters {
            let source = try sourceForAdapter(adapter, in: context)
            guard source.isEnabled else { continue }

            do {
                let drafts = try await adapter.fetchContent(since: startDate, until: endDate)
                let existingEvents = try fetchEvents(from: startDate, until: endDate, in: context)
                    .filter { $0.sourceIdentifier == source.identifier }
                var existingByID: [String: ContentEvent] = [:]
                for event in existingEvents {
                    existingByID[event.externalID] = event
                }

                var importedForSource = 0
                for draft in drafts {
                    if let event = existingByID.removeValue(forKey: draft.id) {
                        event.sourceName = draft.sourceName
                        event.receivedAt = draft.receivedAt
                        event.title = draft.title
                        event.body = draft.body
                        event.urlString = draft.url?.absoluteString
                        event.category = draft.category
                        event.source = source
                    } else {
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
                        importedForSource += 1
                    }
                }

                for staleEvent in existingByID.values {
                    context.delete(staleEvent)
                }

                source.lastFetchedAt = .now
                source.lastErrorMessage = nil
                source.updatedAt = .now
                report.importedItemCount += importedForSource
                report.refreshedSourceCount += 1
            } catch {
                let message = conciseMessage(for: error)
                source.lastErrorMessage = message
                source.updatedAt = .now
                report.failures.append(ContentRefreshFailure(sourceName: source.name, message: message))
            }
        }

        try context.save()
        return report
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

    static func fetchSources(in context: ModelContext) throws -> [ContentSource] {
        try context.fetch(FetchDescriptor<ContentSource>(sortBy: [SortDescriptor(\.name)]))
    }

    private static func adapter(for source: ContentSource) throws -> ContentSourceAdapter {
        switch source.kind {
        case .sample:
            return SampleContentAdapter()
        case .rss:
            guard let endpointURLString = source.endpointURLString else {
                throw FeedSourceError.invalidURL
            }
            let endpointURL = try FeedURLPolicy.validatedPublicHTTPSURL(from: endpointURLString)
            return RSSFeedAdapter(configuration: FeedSourceConfiguration(
                identifier: source.identifier,
                displayName: source.name,
                endpointURL: endpointURL,
                category: source.defaultCategory,
                includeKeywords: source.includeKeywords,
                excludeKeywords: source.excludeKeywords,
                maxItems: source.maxItemsPerRefresh
            ))
        }
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

        let kind: ContentSourceKind = adapter is SampleContentAdapter ? .sample : .rss
        let source = ContentSource(identifier: adapter.identifier, name: adapter.displayName, kind: kind)
        context.insert(source)
        return source
    }

    private static func conciseMessage(for error: Error) -> String {
        String(error.localizedDescription.prefix(300))
    }
}
