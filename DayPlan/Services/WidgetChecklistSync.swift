import SwiftData
import UserNotifications

enum WidgetChecklistSync {
    static func publish(
        _ checklist: DailyChecklist,
        defaults: UserDefaults? = nil,
        reloadWidgets: Bool = true
    ) {
        guard DateKeys.dayKey(for: checklist.date) == DateKeys.dayKey(for: .now) else { return }

        let items = checklist.items
            .sorted {
                if $0.sortOrder == $1.sortOrder {
                    return $0.createdAt < $1.createdAt
                }
                return $0.sortOrder < $1.sortOrder
            }
            .map { item in
                WidgetChecklistItem(
                    id: item.id,
                    title: item.title,
                    isCompleted: item.isCompleted,
                    sortOrder: item.sortOrder,
                    reminderIdentifiers: item.reminders
                        .filter(\.isEnabled)
                        .map(\.notificationIdentifier)
                )
            }

        let snapshot = WidgetChecklistSnapshot(
            dayKey: DateKeys.dayKey(for: checklist.date),
            generatedAt: .now,
            items: items
        )
        WidgetChecklistStore.save(
            snapshot,
            defaults: defaults,
            reloadWidgets: reloadWidgets
        )
    }

    static func publishToday(
        in context: ModelContext,
        defaults: UserDefaults? = nil,
        reloadWidgets: Bool = true
    ) throws {
        let today = DateKeys.startOfDay(.now)
        var descriptor = FetchDescriptor<DailyChecklist>(
            predicate: #Predicate { checklist in
                checklist.date == today
            }
        )
        descriptor.fetchLimit = 1

        if let checklist = try context.fetch(descriptor).first {
            publish(checklist, defaults: defaults, reloadWidgets: reloadWidgets)
        }
    }

    static func applyPendingMutations(
        in context: ModelContext,
        defaults: UserDefaults? = nil,
        reloadWidgets: Bool = true
    ) throws {
        let mutations = WidgetChecklistStore.pendingMutations(defaults: defaults)
        guard !mutations.isEmpty else { return }

        var acknowledgedIDs = Set<UUID>()
        var reminderIdentifiersToCancel = Set<String>()
        var didChange = false

        for mutation in mutations {
            let itemID = mutation.itemID
            var descriptor = FetchDescriptor<DailyChecklistItem>(
                predicate: #Predicate { item in
                    item.id == itemID
                }
            )
            descriptor.fetchLimit = 1

            guard let item = try context.fetch(descriptor).first else {
                acknowledgedIDs.insert(mutation.id)
                continue
            }

            guard
                let checklistDate = item.checklist?.date,
                DateKeys.dayKey(for: checklistDate) == mutation.dayKey
            else {
                acknowledgedIDs.insert(mutation.id)
                continue
            }

            if item.isCompleted != mutation.isCompleted {
                item.isCompleted = mutation.isCompleted
                item.completedAt = mutation.isCompleted ? mutation.occurredAt : nil
                item.updatedAt = mutation.occurredAt
                item.checklist?.updatedAt = mutation.occurredAt
                didChange = true
            }

            if mutation.isCompleted {
                reminderIdentifiersToCancel.formUnion(mutation.reminderIdentifiers)
            }
            acknowledgedIDs.insert(mutation.id)
        }

        if didChange {
            try context.save()
        }

        if !reminderIdentifiersToCancel.isEmpty {
            UNUserNotificationCenter.current().removePendingNotificationRequests(
                withIdentifiers: Array(reminderIdentifiersToCancel)
            )
        }

        WidgetChecklistStore.acknowledge(mutationIDs: acknowledgedIDs, defaults: defaults)
        try publishToday(in: context, defaults: defaults, reloadWidgets: reloadWidgets)
    }
}
