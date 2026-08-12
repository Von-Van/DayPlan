import Foundation
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct DayPlanArchiveDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    var data: Data

    init(data: Data = Data()) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

enum DataArchiveError: LocalizedError, Equatable {
    case unsupportedArchive

    var errorDescription: String? {
        switch self {
        case .unsupportedArchive:
            "This file is not a supported DayPlan backup."
        }
    }
}

enum DataArchiveService {
    static let currentVersion = 2

    static func exportData(in context: ModelContext, exportedAt: Date = .now) throws -> Data {
        let archive = DayPlanArchive(
            exportedAt: exportedAt,
            templates: try context.fetch(FetchDescriptor<ChecklistTemplateItem>()).map(TemplateArchive.init),
            dailyChecklists: try context.fetch(FetchDescriptor<DailyChecklist>()).map(DailyChecklistArchive.init),
            collections: try context.fetch(FetchDescriptor<CollectionList>()).map(CollectionArchive.init),
            goals: try context.fetch(FetchDescriptor<Goal>()).map(GoalArchive.init),
            contentSources: try context.fetch(FetchDescriptor<ContentSource>()).map(ContentSourceArchive.init),
            contentEvents: try context.fetch(FetchDescriptor<ContentEvent>()).map(ContentEventArchive.init),
            contentDigests: try context.fetch(FetchDescriptor<DailyContentDigest>()).map(ContentDigestArchive.init),
            suggestionDecisions: try context.fetch(FetchDescriptor<ContentSuggestionDecision>()).map(SuggestionDecisionArchive.init),
            suggestionSourceRules: try context.fetch(FetchDescriptor<ContentSuggestionSourceRule>()).map(SuggestionSourceRuleArchive.init)
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(archive)
    }

    static func replaceData(with data: Data, in context: ModelContext) throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let header = try decoder.decode(DayPlanArchiveHeader.self, from: data)
        guard header.appName == "DayPlan", (1...currentVersion).contains(header.schemaVersion) else {
            throw DataArchiveError.unsupportedArchive
        }

        let archive = try decoder.decode(DayPlanArchive.self, from: data)
        try deleteExistingData(in: context)
        try insert(archive, in: context)
        try context.save()
        #if os(iOS)
        try WidgetChecklistSync.publishToday(in: context)
        #endif
    }

    private static func deleteExistingData(in context: ModelContext) throws {
        try delete(ContentSuggestionDecision.self, in: context)
        try delete(ContentSuggestionSourceRule.self, in: context)
        try delete(DailyContentDigest.self, in: context)
        try delete(ContentEvent.self, in: context)
        try delete(ContentSource.self, in: context)
        try delete(CollectionItem.self, in: context)
        try delete(CollectionList.self, in: context)
        try delete(GoalAction.self, in: context)
        try delete(Goal.self, in: context)
        try delete(ReminderSchedule.self, in: context)
        try delete(DailyChecklistItem.self, in: context)
        try delete(DailyChecklist.self, in: context)
        try delete(ChecklistTemplateItem.self, in: context)
        try context.save()
    }

    private static func delete<Model: PersistentModel>(_ type: Model.Type, in context: ModelContext) throws {
        for model in try context.fetch(FetchDescriptor<Model>()) {
            context.delete(model)
        }
    }

    private static func insert(_ archive: DayPlanArchive, in context: ModelContext) throws {
        for template in archive.templates {
            context.insert(template.model)
        }

        for archivedChecklist in archive.dailyChecklists {
            let checklist = archivedChecklist.model
            context.insert(checklist)

            for archivedItem in archivedChecklist.items {
                let item = archivedItem.model(checklist: checklist)
                checklist.items.append(item)
                context.insert(item)

                for archivedReminder in archivedItem.reminders {
                    let reminder = archivedReminder.model
                    item.reminders.append(reminder)
                    context.insert(reminder)
                }
            }
        }

        for archivedCollection in archive.collections {
            let collection = archivedCollection.model
            context.insert(collection)

            for archivedItem in archivedCollection.items {
                let item = archivedItem.model(collection: collection)
                collection.items.append(item)
                context.insert(item)
            }
        }

        for archivedGoal in archive.goals {
            let goal = archivedGoal.model
            context.insert(goal)

            for archivedAction in archivedGoal.actions {
                let action = archivedAction.model(goal: goal)
                goal.actions.append(action)
                context.insert(action)
            }
        }

        var sourcesByIdentifier: [String: ContentSource] = [:]
        for archivedSource in archive.contentSources {
            let source = archivedSource.model
            sourcesByIdentifier[source.identifier] = source
            context.insert(source)
        }

        for archivedEvent in archive.contentEvents {
            let source = sourcesByIdentifier[archivedEvent.sourceIdentifier]
            let event = archivedEvent.model(source: source)
            source?.events.append(event)
            context.insert(event)
        }

        for digest in archive.contentDigests {
            context.insert(digest.model)
        }

        for decision in archive.suggestionDecisions {
            context.insert(decision.model)
        }

        for rule in archive.suggestionSourceRules {
            context.insert(rule.model)
        }
    }
}

private struct DayPlanArchiveHeader: Decodable {
    let appName: String
    let schemaVersion: Int
}

private struct DayPlanArchive: Codable {
    let appName: String
    let schemaVersion: Int
    let exportedAt: Date
    let templates: [TemplateArchive]
    let dailyChecklists: [DailyChecklistArchive]
    let collections: [CollectionArchive]
    let goals: [GoalArchive]
    let contentSources: [ContentSourceArchive]
    let contentEvents: [ContentEventArchive]
    let contentDigests: [ContentDigestArchive]
    let suggestionDecisions: [SuggestionDecisionArchive]
    let suggestionSourceRules: [SuggestionSourceRuleArchive]

    init(
        exportedAt: Date,
        templates: [TemplateArchive],
        dailyChecklists: [DailyChecklistArchive],
        collections: [CollectionArchive],
        goals: [GoalArchive],
        contentSources: [ContentSourceArchive],
        contentEvents: [ContentEventArchive],
        contentDigests: [ContentDigestArchive],
        suggestionDecisions: [SuggestionDecisionArchive],
        suggestionSourceRules: [SuggestionSourceRuleArchive]
    ) {
        appName = "DayPlan"
        schemaVersion = DataArchiveService.currentVersion
        self.exportedAt = exportedAt
        self.templates = templates
        self.dailyChecklists = dailyChecklists
        self.collections = collections
        self.goals = goals
        self.contentSources = contentSources
        self.contentEvents = contentEvents
        self.contentDigests = contentDigests
        self.suggestionDecisions = suggestionDecisions
        self.suggestionSourceRules = suggestionSourceRules
    }

    enum CodingKeys: String, CodingKey {
        case appName
        case schemaVersion
        case exportedAt
        case templates
        case dailyChecklists
        case collections
        case goals
        case contentSources
        case contentEvents
        case contentDigests
        case suggestionDecisions
        case suggestionSourceRules
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        appName = try container.decode(String.self, forKey: .appName)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        exportedAt = try container.decode(Date.self, forKey: .exportedAt)
        templates = try container.decode([TemplateArchive].self, forKey: .templates)
        dailyChecklists = try container.decode([DailyChecklistArchive].self, forKey: .dailyChecklists)
        collections = try container.decode([CollectionArchive].self, forKey: .collections)
        goals = try container.decodeIfPresent([GoalArchive].self, forKey: .goals) ?? []
        contentSources = try container.decode([ContentSourceArchive].self, forKey: .contentSources)
        contentEvents = try container.decode([ContentEventArchive].self, forKey: .contentEvents)
        contentDigests = try container.decode([ContentDigestArchive].self, forKey: .contentDigests)
        suggestionDecisions = try container.decode([SuggestionDecisionArchive].self, forKey: .suggestionDecisions)
        suggestionSourceRules = try container.decodeIfPresent(
            [SuggestionSourceRuleArchive].self,
            forKey: .suggestionSourceRules
        ) ?? []
    }
}

private struct TemplateArchive: Codable {
    let id: UUID
    let title: String
    let notes: String
    let isActive: Bool
    let goalID: UUID?
    let sortOrder: Int
    let createdAt: Date
    let updatedAt: Date

    init(_ template: ChecklistTemplateItem) {
        id = template.id
        title = template.title
        notes = template.notes
        isActive = template.isActive
        goalID = template.goalID
        sortOrder = template.sortOrder
        createdAt = template.createdAt
        updatedAt = template.updatedAt
    }

    var model: ChecklistTemplateItem {
        ChecklistTemplateItem(
            id: id,
            title: title,
            notes: notes,
            isActive: isActive,
            goalID: goalID,
            sortOrder: sortOrder,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}

private struct ReminderArchive: Codable {
    let id: UUID
    let itemID: UUID
    let checklistDate: Date
    let hour: Int
    let minute: Int
    let isEnabled: Bool
    let createdAt: Date
    let updatedAt: Date

    init(_ reminder: ReminderSchedule) {
        id = reminder.id
        itemID = reminder.itemID
        checklistDate = reminder.checklistDate
        hour = reminder.hour
        minute = reminder.minute
        isEnabled = reminder.isEnabled
        createdAt = reminder.createdAt
        updatedAt = reminder.updatedAt
    }

    var model: ReminderSchedule {
        ReminderSchedule(
            id: id,
            itemID: itemID,
            checklistDate: checklistDate,
            hour: hour,
            minute: minute,
            isEnabled: isEnabled,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}

private struct DailyChecklistItemArchive: Codable {
    let id: UUID
    let title: String
    let notes: String
    let isCompleted: Bool
    let completedAt: Date?
    let isPersistent: Bool
    let templateID: UUID?
    let goalID: UUID?
    let goalActionID: UUID?
    let sortOrder: Int
    let createdAt: Date
    let updatedAt: Date
    let reminders: [ReminderArchive]

    init(_ item: DailyChecklistItem) {
        id = item.id
        title = item.title
        notes = item.notes
        isCompleted = item.isCompleted
        completedAt = item.completedAt
        isPersistent = item.isPersistent
        templateID = item.templateID
        goalID = item.goalID
        goalActionID = item.goalActionID
        sortOrder = item.sortOrder
        createdAt = item.createdAt
        updatedAt = item.updatedAt
        reminders = item.reminders.map(ReminderArchive.init)
    }

    func model(checklist: DailyChecklist) -> DailyChecklistItem {
        DailyChecklistItem(
            id: id,
            title: title,
            notes: notes,
            isCompleted: isCompleted,
            completedAt: completedAt,
            isPersistent: isPersistent,
            templateID: templateID,
            goalID: goalID,
            goalActionID: goalActionID,
            sortOrder: sortOrder,
            createdAt: createdAt,
            updatedAt: updatedAt,
            checklist: checklist
        )
    }
}

private struct DailyChecklistArchive: Codable {
    let id: UUID
    let date: Date
    let createdAt: Date
    let updatedAt: Date
    let items: [DailyChecklistItemArchive]

    init(_ checklist: DailyChecklist) {
        id = checklist.id
        date = checklist.date
        createdAt = checklist.createdAt
        updatedAt = checklist.updatedAt
        items = checklist.items.map(DailyChecklistItemArchive.init)
    }

    var model: DailyChecklist {
        DailyChecklist(id: id, date: date, createdAt: createdAt, updatedAt: updatedAt)
    }
}

private struct CollectionItemArchive: Codable {
    let id: UUID
    let title: String
    let notes: String
    let priorityRawValue: String
    let tagString: String
    let isCompleted: Bool
    let completedAt: Date?
    let goalID: UUID?
    let sortOrder: Int
    let createdAt: Date
    let updatedAt: Date

    init(_ item: CollectionItem) {
        id = item.id
        title = item.title
        notes = item.notes
        priorityRawValue = item.priorityRawValue
        tagString = item.tagString
        isCompleted = item.isCompleted
        completedAt = item.completedAt
        goalID = item.goalID
        sortOrder = item.sortOrder
        createdAt = item.createdAt
        updatedAt = item.updatedAt
    }

    func model(collection: CollectionList) -> CollectionItem {
        let item = CollectionItem(
            id: id,
            title: title,
            notes: notes,
            priority: CollectionPriority(rawValue: priorityRawValue) ?? .none,
            isCompleted: isCompleted,
            completedAt: completedAt,
            goalID: goalID,
            sortOrder: sortOrder,
            createdAt: createdAt,
            updatedAt: updatedAt,
            collection: collection
        )
        item.tagString = tagString
        return item
    }
}

private struct CollectionArchive: Codable {
    let id: UUID
    let name: String
    let details: String
    let colorName: String
    let createdAt: Date
    let updatedAt: Date
    let items: [CollectionItemArchive]

    init(_ collection: CollectionList) {
        id = collection.id
        name = collection.name
        details = collection.details
        colorName = collection.colorName
        createdAt = collection.createdAt
        updatedAt = collection.updatedAt
        items = collection.items.map(CollectionItemArchive.init)
    }

    var model: CollectionList {
        CollectionList(
            id: id,
            name: name,
            details: details,
            colorName: colorName,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}

private struct GoalActionArchive: Codable {
    let id: UUID
    let title: String
    let notes: String
    let priorityRawValue: String
    let isCompleted: Bool
    let completedAt: Date?
    let scheduledDate: Date?
    let scheduledChecklistItemID: UUID?
    let sortOrder: Int
    let createdAt: Date
    let updatedAt: Date

    init(_ action: GoalAction) {
        id = action.id
        title = action.title
        notes = action.notes
        priorityRawValue = action.priorityRawValue
        isCompleted = action.isCompleted
        completedAt = action.completedAt
        scheduledDate = action.scheduledDate
        scheduledChecklistItemID = action.scheduledChecklistItemID
        sortOrder = action.sortOrder
        createdAt = action.createdAt
        updatedAt = action.updatedAt
    }

    func model(goal: Goal) -> GoalAction {
        GoalAction(
            id: id,
            title: title,
            notes: notes,
            priority: CollectionPriority(rawValue: priorityRawValue) ?? .none,
            isCompleted: isCompleted,
            completedAt: completedAt,
            scheduledDate: scheduledDate,
            scheduledChecklistItemID: scheduledChecklistItemID,
            sortOrder: sortOrder,
            createdAt: createdAt,
            updatedAt: updatedAt,
            goal: goal
        )
    }
}

private struct GoalArchive: Codable {
    let id: UUID
    let title: String
    let details: String
    let colorName: String
    let targetDate: Date?
    let archivedAt: Date?
    let sortOrder: Int
    let createdAt: Date
    let updatedAt: Date
    let actions: [GoalActionArchive]

    init(_ goal: Goal) {
        id = goal.id
        title = goal.title
        details = goal.details
        colorName = goal.colorName
        targetDate = goal.targetDate
        archivedAt = goal.archivedAt
        sortOrder = goal.sortOrder
        createdAt = goal.createdAt
        updatedAt = goal.updatedAt
        actions = goal.actions.map(GoalActionArchive.init)
    }

    var model: Goal {
        Goal(
            id: id,
            title: title,
            details: details,
            colorName: colorName,
            targetDate: targetDate,
            archivedAt: archivedAt,
            sortOrder: sortOrder,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}

private struct ContentSourceArchive: Codable {
    let id: UUID
    let identifier: String
    let name: String
    let isEnabled: Bool
    let kindRawValue: String
    let endpointURLString: String?
    let defaultCategoryRawValue: String
    let includeKeywordsString: String
    let excludeKeywordsString: String
    let maxItemsPerRefresh: Int
    let lastFetchedAt: Date?
    let lastErrorMessage: String?
    let createdAt: Date
    let updatedAt: Date

    init(_ source: ContentSource) {
        id = source.id
        identifier = source.identifier
        name = source.name
        isEnabled = source.isEnabled
        kindRawValue = source.kindRawValue
        endpointURLString = source.endpointURLString
        defaultCategoryRawValue = source.defaultCategoryRawValue
        includeKeywordsString = source.includeKeywordsString
        excludeKeywordsString = source.excludeKeywordsString
        maxItemsPerRefresh = source.maxItemsPerRefresh
        lastFetchedAt = source.lastFetchedAt
        lastErrorMessage = source.lastErrorMessage
        createdAt = source.createdAt
        updatedAt = source.updatedAt
    }

    var model: ContentSource {
        let source = ContentSource(
            id: id,
            identifier: identifier,
            name: name,
            isEnabled: isEnabled,
            kind: ContentSourceKind(rawValue: kindRawValue) ?? .sample,
            endpointURLString: endpointURLString,
            defaultCategory: ContentCategory(rawValue: defaultCategoryRawValue) ?? .article,
            maxItemsPerRefresh: maxItemsPerRefresh,
            lastFetchedAt: lastFetchedAt,
            lastErrorMessage: lastErrorMessage,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
        source.includeKeywordsString = includeKeywordsString
        source.excludeKeywordsString = excludeKeywordsString
        return source
    }
}

private struct ContentEventArchive: Codable {
    let id: UUID
    let externalID: String
    let sourceIdentifier: String
    let sourceName: String
    let receivedAt: Date
    let title: String
    let body: String
    let urlString: String?
    let categoryRawValue: String
    let isRead: Bool
    let createdAt: Date

    init(_ event: ContentEvent) {
        id = event.id
        externalID = event.externalID
        sourceIdentifier = event.sourceIdentifier
        sourceName = event.sourceName
        receivedAt = event.receivedAt
        title = event.title
        body = event.body
        urlString = event.urlString
        categoryRawValue = event.categoryRawValue
        isRead = event.isRead
        createdAt = event.createdAt
    }

    func model(source: ContentSource?) -> ContentEvent {
        ContentEvent(
            id: id,
            externalID: externalID,
            sourceIdentifier: sourceIdentifier,
            sourceName: sourceName,
            receivedAt: receivedAt,
            title: title,
            body: body,
            urlString: urlString,
            category: ContentCategory(rawValue: categoryRawValue) ?? .other,
            isRead: isRead,
            createdAt: createdAt,
            source: source
        )
    }
}

private struct ContentDigestArchive: Codable {
    let id: UUID
    let date: Date
    let summary: String
    let generatedAt: Date

    init(_ digest: DailyContentDigest) {
        id = digest.id
        date = digest.date
        summary = digest.summary
        generatedAt = digest.generatedAt
    }

    var model: DailyContentDigest {
        DailyContentDigest(id: id, date: date, summary: summary, generatedAt: generatedAt)
    }
}

private struct SuggestionDecisionArchive: Codable {
    let id: UUID
    let eventKey: String
    let statusRawValue: String
    let decidedAt: Date
    let checklistItemID: UUID?

    init(_ decision: ContentSuggestionDecision) {
        id = decision.id
        eventKey = decision.eventKey
        statusRawValue = decision.statusRawValue
        decidedAt = decision.decidedAt
        checklistItemID = decision.checklistItemID
    }

    var model: ContentSuggestionDecision {
        ContentSuggestionDecision(
            id: id,
            eventKey: eventKey,
            status: ContentSuggestionStatus(rawValue: statusRawValue) ?? .dismissed,
            decidedAt: decidedAt,
            checklistItemID: checklistItemID
        )
    }
}

private struct SuggestionSourceRuleArchive: Codable {
    let id: UUID
    let sourceIdentifier: String
    let isEnabled: Bool
    let priorityRawValue: String
    let includeKeywordsString: String
    let excludeKeywordsString: String
    let createdAt: Date
    let updatedAt: Date

    init(_ rule: ContentSuggestionSourceRule) {
        id = rule.id
        sourceIdentifier = rule.sourceIdentifier
        isEnabled = rule.isEnabled
        priorityRawValue = rule.priorityRawValue
        includeKeywordsString = rule.includeKeywordsString
        excludeKeywordsString = rule.excludeKeywordsString
        createdAt = rule.createdAt
        updatedAt = rule.updatedAt
    }

    var model: ContentSuggestionSourceRule {
        let rule = ContentSuggestionSourceRule(
            id: id,
            sourceIdentifier: sourceIdentifier,
            isEnabled: isEnabled,
            priority: ContentSuggestionSourcePriority(rawValue: priorityRawValue) ?? .normal,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
        rule.includeKeywordsString = includeKeywordsString
        rule.excludeKeywordsString = excludeKeywordsString
        return rule
    }
}
