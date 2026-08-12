import Foundation
import SwiftData

struct GoalProgressSummary: Equatable {
    let completed: Int
    let total: Int

    var percentage: Int {
        guard total > 0 else { return 0 }
        return Int((Double(completed) / Double(total) * 100).rounded())
    }
}

enum GoalStoreError: LocalizedError, Equatable {
    case actionHasNoGoal

    var errorDescription: String? {
        switch self {
        case .actionHasNoGoal:
            "This action is not attached to a goal."
        }
    }
}

enum GoalStore {
    static func createGoal(
        title: String,
        details: String = "",
        colorName: String = "green",
        targetDate: Date? = nil,
        in context: ModelContext
    ) throws -> Goal {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let goal = Goal(
            title: cleanTitle,
            details: details,
            colorName: colorName,
            targetDate: targetDate,
            sortOrder: try activeGoals(in: context).count
        )
        context.insert(goal)
        try context.save()
        return goal
    }

    static func activeGoals(in context: ModelContext) throws -> [Goal] {
        try context.fetch(FetchDescriptor<Goal>(
            sortBy: [
                SortDescriptor(\.sortOrder),
                SortDescriptor(\.createdAt)
            ]
        ))
        .filter { !$0.isArchived }
    }

    static func archive(_ goal: Goal, at date: Date = .now, in context: ModelContext) throws {
        goal.archivedAt = date
        goal.updatedAt = date
        try context.save()
    }

    static func addAction(
        title: String,
        notes: String = "",
        priority: CollectionPriority = .none,
        to goal: Goal,
        in context: ModelContext
    ) throws -> GoalAction {
        let action = GoalAction(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            notes: notes,
            priority: priority,
            sortOrder: goal.actions.count,
            goal: goal
        )
        goal.actions.append(action)
        goal.updatedAt = .now
        context.insert(action)
        try context.save()
        return action
    }

    static func setActionCompletion(
        _ action: GoalAction,
        isCompleted: Bool,
        in context: ModelContext
    ) throws {
        let completedAt = isCompleted ? Date.now : nil
        action.isCompleted = isCompleted
        action.completedAt = completedAt
        action.updatedAt = .now
        action.goal?.updatedAt = .now

        if let item = try scheduledChecklistItem(for: action, in: context),
           item.isCompleted != isCompleted {
            item.isCompleted = isCompleted
            item.completedAt = completedAt
            item.updatedAt = .now
            item.checklist?.updatedAt = .now
        }

        try context.save()
    }

    @discardableResult
    static func schedule(
        _ action: GoalAction,
        for date: Date,
        in context: ModelContext
    ) throws -> DailyChecklistItem {
        if let existing = try scheduledChecklistItem(for: action, in: context) {
            return existing
        }

        guard let goalID = action.goal?.id else {
            throw GoalStoreError.actionHasNoGoal
        }

        let checklist = try ChecklistStore.checklist(for: date, in: context)
        guard let checklist else {
            throw GoalStoreError.actionHasNoGoal
        }

        let item = try ChecklistStore.addItem(
            title: action.title,
            notes: action.notes,
            goalID: goalID,
            goalActionID: action.id,
            to: checklist,
            in: context
        )
        if action.isCompleted {
            try ChecklistStore.toggleCompletion(for: item, isCompleted: true, in: context)
        }

        action.scheduledDate = DateKeys.startOfDay(date)
        action.scheduledChecklistItemID = item.id
        action.updatedAt = .now
        action.goal?.updatedAt = .now
        try context.save()
        return item
    }

    static func link(_ item: DailyChecklistItem, to goal: Goal, in context: ModelContext) throws {
        try ChecklistStore.setGoal(goal.id, for: item, in: context)
    }

    static func unlink(_ item: DailyChecklistItem, in context: ModelContext) throws {
        try ChecklistStore.setGoal(nil, for: item, in: context)
    }

    static func link(_ item: CollectionItem, to goal: Goal, in context: ModelContext) throws {
        item.goalID = goal.id
        item.updatedAt = .now
        item.collection?.updatedAt = .now
        goal.updatedAt = .now
        try context.save()
    }

    static func unlink(_ item: CollectionItem, in context: ModelContext) throws {
        item.goalID = nil
        item.updatedAt = .now
        item.collection?.updatedAt = .now
        try context.save()
    }

    static func mirrorCompletion(from item: DailyChecklistItem, in context: ModelContext) throws {
        guard let actionID = item.goalActionID,
              let action = try action(withID: actionID, in: context)
        else {
            return
        }

        action.isCompleted = item.isCompleted
        action.completedAt = item.completedAt
        action.scheduledDate = item.checklist?.date
        action.scheduledChecklistItemID = item.id
        action.updatedAt = .now
        action.goal?.updatedAt = .now
    }

    static func unlinkScheduledAction(for item: DailyChecklistItem, in context: ModelContext) throws {
        guard let actionID = item.goalActionID,
              let action = try action(withID: actionID, in: context)
        else {
            return
        }

        if action.scheduledChecklistItemID == nil || action.scheduledChecklistItemID == item.id {
            action.scheduledDate = nil
            action.scheduledChecklistItemID = nil
            action.updatedAt = .now
            action.goal?.updatedAt = .now
        }
    }

    static func progress(for goal: Goal, in context: ModelContext) throws -> GoalProgressSummary {
        let dailyItems = try context.fetch(FetchDescriptor<DailyChecklistItem>())
            .filter { $0.goalID == goal.id && $0.goalActionID == nil }
        let collectionItems = try context.fetch(FetchDescriptor<CollectionItem>())
            .filter { $0.goalID == goal.id }

        let completed = goal.actions.filter(\.isCompleted).count
            + dailyItems.filter(\.isCompleted).count
            + collectionItems.filter(\.isCompleted).count
        let total = goal.actions.count + dailyItems.count + collectionItems.count
        return GoalProgressSummary(completed: completed, total: total)
    }

    static func sortedActions(for goal: Goal) -> [GoalAction] {
        goal.actions.sorted {
            if $0.sortOrder == $1.sortOrder {
                return $0.createdAt < $1.createdAt
            }
            return $0.sortOrder < $1.sortOrder
        }
    }

    private static func scheduledChecklistItem(
        for action: GoalAction,
        in context: ModelContext
    ) throws -> DailyChecklistItem? {
        guard let itemID = action.scheduledChecklistItemID else { return nil }
        return try checklistItem(withID: itemID, in: context)
    }

    private static func checklistItem(
        withID itemID: UUID,
        in context: ModelContext
    ) throws -> DailyChecklistItem? {
        var descriptor = FetchDescriptor<DailyChecklistItem>(
            predicate: #Predicate { item in
                item.id == itemID
            }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private static func action(withID actionID: UUID, in context: ModelContext) throws -> GoalAction? {
        var descriptor = FetchDescriptor<GoalAction>(
            predicate: #Predicate { action in
                action.id == actionID
            }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }
}
