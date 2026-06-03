import Foundation
import SwiftData

enum CollectionPriority: String, Codable, CaseIterable, Identifiable {
    case none
    case low
    case medium
    case high

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none: "None"
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        }
    }
}

enum ContentCategory: String, Codable, CaseIterable, Identifiable {
    case alert
    case message
    case calendar
    case task
    case article
    case other

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .alert: "Alerts"
        case .message: "Messages"
        case .calendar: "Calendar"
        case .task: "Tasks"
        case .article: "Articles"
        case .other: "Other"
        }
    }
}

@Model
final class ChecklistTemplateItem: Identifiable {
    @Attribute(.unique) var id: UUID
    var title: String
    var notes: String
    var isActive: Bool
    var sortOrder: Int
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        title: String,
        notes: String = "",
        isActive: Bool = true,
        sortOrder: Int = 0,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.title = title
        self.notes = notes
        self.isActive = isActive
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

@Model
final class DailyChecklist: Identifiable {
    @Attribute(.unique) var id: UUID
    var date: Date
    var createdAt: Date
    var updatedAt: Date

    @Relationship(deleteRule: .cascade, inverse: \DailyChecklistItem.checklist)
    var items: [DailyChecklistItem]

    init(id: UUID = UUID(), date: Date, createdAt: Date = .now, updatedAt: Date = .now) {
        self.id = id
        self.date = date
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.items = []
    }

    var completedCount: Int {
        items.filter(\.isCompleted).count
    }

    var completionPercentage: Int {
        guard !items.isEmpty else { return 0 }
        return Int((Double(completedCount) / Double(items.count) * 100).rounded())
    }
}

@Model
final class DailyChecklistItem: Identifiable {
    @Attribute(.unique) var id: UUID
    var title: String
    var notes: String
    var isCompleted: Bool
    var completedAt: Date?
    var isPersistent: Bool
    var templateID: UUID?
    var sortOrder: Int
    var createdAt: Date
    var updatedAt: Date

    var checklist: DailyChecklist?

    @Relationship(deleteRule: .cascade)
    var reminders: [ReminderSchedule]

    init(
        id: UUID = UUID(),
        title: String,
        notes: String = "",
        isCompleted: Bool = false,
        completedAt: Date? = nil,
        isPersistent: Bool = false,
        templateID: UUID? = nil,
        sortOrder: Int = 0,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        checklist: DailyChecklist? = nil
    ) {
        self.id = id
        self.title = title
        self.notes = notes
        self.isCompleted = isCompleted
        self.completedAt = completedAt
        self.isPersistent = isPersistent
        self.templateID = templateID
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.checklist = checklist
        self.reminders = []
    }
}

@Model
final class ReminderSchedule: Identifiable {
    @Attribute(.unique) var id: UUID
    var itemID: UUID
    var checklistDate: Date
    var hour: Int
    var minute: Int
    var isEnabled: Bool
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        itemID: UUID,
        checklistDate: Date,
        hour: Int,
        minute: Int,
        isEnabled: Bool = true,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.itemID = itemID
        self.checklistDate = checklistDate
        self.hour = hour
        self.minute = minute
        self.isEnabled = isEnabled
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var notificationIdentifier: String {
        let key = DateKeys.dayKey(for: checklistDate)
        return "dayplan.checklist.\(key).\(itemID.uuidString).\(hour)-\(minute)"
    }
}

@Model
final class CollectionList: Identifiable {
    @Attribute(.unique) var id: UUID
    var name: String
    var details: String
    var colorName: String
    var createdAt: Date
    var updatedAt: Date

    @Relationship(deleteRule: .cascade, inverse: \CollectionItem.collection)
    var items: [CollectionItem]

    init(
        id: UUID = UUID(),
        name: String,
        details: String = "",
        colorName: String = "blue",
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.details = details
        self.colorName = colorName
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.items = []
    }

    var completedCount: Int {
        items.filter(\.isCompleted).count
    }

    var completionPercentage: Int {
        guard !items.isEmpty else { return 0 }
        return Int((Double(completedCount) / Double(items.count) * 100).rounded())
    }
}

@Model
final class CollectionItem: Identifiable {
    @Attribute(.unique) var id: UUID
    var title: String
    var notes: String
    var priorityRawValue: String
    var tagString: String
    var isCompleted: Bool
    var completedAt: Date?
    var sortOrder: Int
    var createdAt: Date
    var updatedAt: Date
    var collection: CollectionList?

    init(
        id: UUID = UUID(),
        title: String,
        notes: String = "",
        priority: CollectionPriority = .none,
        tags: [String] = [],
        isCompleted: Bool = false,
        completedAt: Date? = nil,
        sortOrder: Int = 0,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        collection: CollectionList? = nil
    ) {
        self.id = id
        self.title = title
        self.notes = notes
        self.priorityRawValue = priority.rawValue
        self.tagString = tags.joined(separator: ",")
        self.isCompleted = isCompleted
        self.completedAt = completedAt
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.collection = collection
    }

    var priority: CollectionPriority {
        get { CollectionPriority(rawValue: priorityRawValue) ?? .none }
        set { priorityRawValue = newValue.rawValue }
    }

    var tags: [String] {
        get {
            tagString
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        set {
            tagString = newValue
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: ",")
        }
    }
}

@Model
final class ContentSource: Identifiable {
    @Attribute(.unique) var id: UUID
    var identifier: String
    var name: String
    var isEnabled: Bool
    var createdAt: Date
    var updatedAt: Date

    @Relationship(deleteRule: .cascade, inverse: \ContentEvent.source)
    var events: [ContentEvent]

    init(
        id: UUID = UUID(),
        identifier: String,
        name: String,
        isEnabled: Bool = true,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.identifier = identifier
        self.name = name
        self.isEnabled = isEnabled
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.events = []
    }
}

@Model
final class ContentEvent: Identifiable {
    @Attribute(.unique) var id: UUID
    var externalID: String
    var sourceIdentifier: String
    var sourceName: String
    var receivedAt: Date
    var title: String
    var body: String
    var urlString: String?
    var categoryRawValue: String
    var isRead: Bool
    var createdAt: Date
    var source: ContentSource?

    init(
        id: UUID = UUID(),
        externalID: String,
        sourceIdentifier: String,
        sourceName: String,
        receivedAt: Date,
        title: String,
        body: String,
        urlString: String? = nil,
        category: ContentCategory = .other,
        isRead: Bool = false,
        createdAt: Date = .now,
        source: ContentSource? = nil
    ) {
        self.id = id
        self.externalID = externalID
        self.sourceIdentifier = sourceIdentifier
        self.sourceName = sourceName
        self.receivedAt = receivedAt
        self.title = title
        self.body = body
        self.urlString = urlString
        self.categoryRawValue = category.rawValue
        self.isRead = isRead
        self.createdAt = createdAt
        self.source = source
    }

    var category: ContentCategory {
        get { ContentCategory(rawValue: categoryRawValue) ?? .other }
        set { categoryRawValue = newValue.rawValue }
    }
}

@Model
final class DailyContentDigest: Identifiable {
    @Attribute(.unique) var id: UUID
    var date: Date
    var summary: String
    var generatedAt: Date

    init(id: UUID = UUID(), date: Date, summary: String, generatedAt: Date = .now) {
        self.id = id
        self.date = date
        self.summary = summary
        self.generatedAt = generatedAt
    }
}
