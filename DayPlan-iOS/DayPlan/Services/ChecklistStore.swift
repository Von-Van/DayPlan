import Foundation
import SwiftData

enum ChecklistStore {
    static func checklist(
        for date: Date,
        in context: ModelContext,
        createIfMissing: Bool = true
    ) throws -> DailyChecklist? {
        let day = DateKeys.startOfDay(date)
        var descriptor = FetchDescriptor<DailyChecklist>(
            predicate: #Predicate { checklist in
                checklist.date == day
            }
        )
        descriptor.fetchLimit = 1

        if let existing = try context.fetch(descriptor).first {
            if createIfMissing {
                try materializeTemplateItems(into: existing, in: context)
            }
            return existing
        }

        guard createIfMissing else { return nil }

        let checklist = DailyChecklist(date: day)
        context.insert(checklist)
        try materializeTemplateItems(into: checklist, in: context)
        try context.save()
        return checklist
    }

    static func addItem(
        title: String,
        notes: String = "",
        to checklist: DailyChecklist,
        in context: ModelContext
    ) throws -> DailyChecklistItem {
        let item = DailyChecklistItem(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            notes: notes,
            sortOrder: checklist.items.count,
            checklist: checklist
        )
        checklist.items.append(item)
        checklist.updatedAt = .now
        context.insert(item)
        try context.save()
        return item
    }

    static func toggleCompletion(
        for item: DailyChecklistItem,
        isCompleted: Bool? = nil,
        in context: ModelContext
    ) throws {
        let nextValue = isCompleted ?? !item.isCompleted
        item.isCompleted = nextValue
        item.completedAt = nextValue ? .now : nil
        item.updatedAt = .now
        item.checklist?.updatedAt = .now
        try context.save()
    }

    static func updateItem(
        _ item: DailyChecklistItem,
        title: String,
        notes: String,
        in context: ModelContext
    ) throws {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        item.title = cleanTitle
        item.notes = notes
        item.updatedAt = .now
        item.checklist?.updatedAt = .now

        if item.isPersistent, let templateID = item.templateID {
            try updateTemplateAndFutureCopies(
                templateID: templateID,
                title: cleanTitle,
                notes: notes,
                from: DateKeys.startOfDay(.now),
                in: context
            )
        }

        try context.save()
    }

    static func setPersistence(
        for item: DailyChecklistItem,
        isPersistent: Bool,
        in context: ModelContext
    ) throws {
        if isPersistent {
            let template: ChecklistTemplateItem
            if let existing = try existingTemplate(for: item, in: context) {
                template = existing
            } else {
                template = ChecklistTemplateItem(
                    title: item.title,
                    notes: item.notes,
                    sortOrder: item.sortOrder
                )
                context.insert(template)
            }

            template.title = item.title
            template.notes = item.notes
            template.isActive = true
            template.updatedAt = .now
            item.isPersistent = true
            item.templateID = template.id
        } else {
            if let templateID = item.templateID {
                try deactivateTemplate(templateID, in: context)
            }
            item.isPersistent = false
            item.templateID = nil
        }

        item.updatedAt = .now
        item.checklist?.updatedAt = .now
        try context.save()
    }

    static func deleteItem(
        _ item: DailyChecklistItem,
        in context: ModelContext
    ) throws {
        item.checklist?.updatedAt = .now
        context.delete(item)
        try context.save()
    }

    static func activeTemplates(in context: ModelContext) throws -> [ChecklistTemplateItem] {
        let descriptor = FetchDescriptor<ChecklistTemplateItem>(
            predicate: #Predicate { template in
                template.isActive
            },
            sortBy: [
                SortDescriptor(\.sortOrder),
                SortDescriptor(\.createdAt)
            ]
        )
        return try context.fetch(descriptor)
    }

    private static func materializeTemplateItems(
        into checklist: DailyChecklist,
        in context: ModelContext
    ) throws {
        let templates = try activeTemplates(in: context)
        let existingTemplateIDs = Set(checklist.items.compactMap(\.templateID))

        for template in templates where !existingTemplateIDs.contains(template.id) {
            let item = DailyChecklistItem(
                title: template.title,
                notes: template.notes,
                isPersistent: true,
                templateID: template.id,
                sortOrder: checklist.items.count,
                checklist: checklist
            )
            checklist.items.append(item)
            context.insert(item)
        }

        checklist.updatedAt = .now
    }

    private static func existingTemplate(
        for item: DailyChecklistItem,
        in context: ModelContext
    ) throws -> ChecklistTemplateItem? {
        guard let templateID = item.templateID else { return nil }
        var descriptor = FetchDescriptor<ChecklistTemplateItem>(
            predicate: #Predicate { template in
                template.id == templateID
            }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private static func deactivateTemplate(
        _ templateID: UUID,
        in context: ModelContext
    ) throws {
        var descriptor = FetchDescriptor<ChecklistTemplateItem>(
            predicate: #Predicate { template in
                template.id == templateID
            }
        )
        descriptor.fetchLimit = 1
        let template = try context.fetch(descriptor).first
        template?.isActive = false
        template?.updatedAt = .now
    }

    private static func updateTemplateAndFutureCopies(
        templateID: UUID,
        title: String,
        notes: String,
        from startDate: Date,
        in context: ModelContext
    ) throws {
        var templateDescriptor = FetchDescriptor<ChecklistTemplateItem>(
            predicate: #Predicate { template in
                template.id == templateID
            }
        )
        templateDescriptor.fetchLimit = 1
        if let template = try context.fetch(templateDescriptor).first {
            template.title = title
            template.notes = notes
            template.updatedAt = .now
        }

        let itemDescriptor = FetchDescriptor<DailyChecklistItem>(
            predicate: #Predicate { copy in
                copy.templateID == templateID
            }
        )

        for copy in try context.fetch(itemDescriptor) where (copy.checklist?.date ?? .distantPast) >= startDate {
            copy.title = title
            copy.notes = notes
            copy.updatedAt = .now
        }
    }
}
