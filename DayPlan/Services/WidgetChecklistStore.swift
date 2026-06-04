import AppIntents
import Foundation
import UserNotifications
import WidgetKit

struct WidgetChecklistItem: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    let title: String
    let isCompleted: Bool
    let sortOrder: Int
    let reminderIdentifiers: [String]
}

struct WidgetChecklistSnapshot: Codable, Hashable, Sendable {
    let dayKey: String
    let generatedAt: Date
    let items: [WidgetChecklistItem]

    var completedCount: Int {
        items.filter(\.isCompleted).count
    }
}

struct WidgetChecklistMutation: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    let dayKey: String
    let itemID: UUID
    let isCompleted: Bool
    let occurredAt: Date
    let reminderIdentifiers: [String]
}

enum WidgetChecklistStore {
    static let appGroupIdentifier = "group.com.jakemauldin.DayPlan"
    static let widgetKind = "DayPlanChecklistWidget"

    private static let snapshotKey = "dayplan.widget.checklist.snapshot.v1"
    private static let mutationKey = "dayplan.widget.checklist.mutations.v1"
    private static let maximumSnapshotItems = 100
    private static let maximumMutations = 200
    private static let maximumTitleLength = 160

    static var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: appGroupIdentifier)
    }

    static func dayKey(for date: Date, calendar: Calendar = .current) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }

    static func snapshot(
        for date: Date = .now,
        defaults suppliedDefaults: UserDefaults? = nil
    ) -> WidgetChecklistSnapshot? {
        guard
            let defaults = suppliedDefaults ?? sharedDefaults,
            let data = defaults.data(forKey: snapshotKey),
            let snapshot = try? JSONDecoder().decode(WidgetChecklistSnapshot.self, from: data),
            snapshot.dayKey == dayKey(for: date)
        else {
            return nil
        }

        return snapshot
    }

    @discardableResult
    static func save(
        _ snapshot: WidgetChecklistSnapshot,
        defaults suppliedDefaults: UserDefaults? = nil,
        reloadWidgets: Bool = true
    ) -> Bool {
        guard let defaults = suppliedDefaults ?? sharedDefaults else { return false }

        var seenIDs = Set<UUID>()
        let boundedItems = snapshot.items
            .filter { seenIDs.insert($0.id).inserted }
            .prefix(maximumSnapshotItems)
            .map { item in
                WidgetChecklistItem(
                    id: item.id,
                    title: String(item.title.prefix(maximumTitleLength)),
                    isCompleted: item.isCompleted,
                    sortOrder: item.sortOrder,
                    reminderIdentifiers: Array(item.reminderIdentifiers.prefix(20))
                )
            }

        let boundedSnapshot = WidgetChecklistSnapshot(
            dayKey: snapshot.dayKey,
            generatedAt: snapshot.generatedAt,
            items: boundedItems
        )

        guard let data = try? JSONEncoder().encode(boundedSnapshot) else { return false }
        defaults.set(data, forKey: snapshotKey)

        if reloadWidgets {
            WidgetCenter.shared.reloadTimelines(ofKind: widgetKind)
        }
        return true
    }

    @discardableResult
    static func toggle(
        itemID: UUID,
        at date: Date = .now,
        defaults suppliedDefaults: UserDefaults? = nil,
        reloadWidgets: Bool = true
    ) -> WidgetChecklistMutation? {
        guard
            let defaults = suppliedDefaults ?? sharedDefaults,
            var snapshot = snapshot(for: date, defaults: defaults),
            let itemIndex = snapshot.items.firstIndex(where: { $0.id == itemID })
        else {
            return nil
        }

        var items = snapshot.items
        let item = items[itemIndex]
        let updatedItem = WidgetChecklistItem(
            id: item.id,
            title: item.title,
            isCompleted: !item.isCompleted,
            sortOrder: item.sortOrder,
            reminderIdentifiers: item.reminderIdentifiers
        )
        items[itemIndex] = updatedItem
        snapshot = WidgetChecklistSnapshot(
            dayKey: snapshot.dayKey,
            generatedAt: date,
            items: items
        )

        let mutation = WidgetChecklistMutation(
            id: UUID(),
            dayKey: snapshot.dayKey,
            itemID: itemID,
            isCompleted: updatedItem.isCompleted,
            occurredAt: date,
            reminderIdentifiers: updatedItem.reminderIdentifiers
        )

        var mutations = pendingMutations(defaults: defaults)
        mutations.append(mutation)
        saveMutations(Array(mutations.suffix(maximumMutations)), defaults: defaults)
        guard save(snapshot, defaults: defaults, reloadWidgets: reloadWidgets) else {
            return nil
        }
        return mutation
    }

    static func pendingMutations(
        defaults suppliedDefaults: UserDefaults? = nil
    ) -> [WidgetChecklistMutation] {
        guard
            let defaults = suppliedDefaults ?? sharedDefaults,
            let data = defaults.data(forKey: mutationKey),
            let mutations = try? JSONDecoder().decode([WidgetChecklistMutation].self, from: data)
        else {
            return []
        }

        return mutations.sorted { $0.occurredAt < $1.occurredAt }
    }

    static func acknowledge(
        mutationIDs: Set<UUID>,
        defaults suppliedDefaults: UserDefaults? = nil
    ) {
        guard !mutationIDs.isEmpty, let defaults = suppliedDefaults ?? sharedDefaults else { return }
        let remaining = pendingMutations(defaults: defaults).filter { !mutationIDs.contains($0.id) }
        saveMutations(remaining, defaults: defaults)
    }

    private static func saveMutations(_ mutations: [WidgetChecklistMutation], defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(mutations) else { return }
        defaults.set(data, forKey: mutationKey)
    }
}

struct ToggleChecklistItemIntent: AppIntent {
    static var title: LocalizedStringResource = "Toggle Checklist Item"
    static var description = IntentDescription("Marks a DayPlan checklist item complete or incomplete.")
    static var openAppWhenRun = false
    static var isDiscoverable = false

    @Parameter(title: "Checklist Item")
    var itemIdentifier: String

    init() {
        itemIdentifier = ""
    }

    init(itemID: UUID) {
        itemIdentifier = itemID.uuidString
    }

    func perform() async throws -> some IntentResult {
        guard
            let itemID = UUID(uuidString: itemIdentifier),
            let mutation = WidgetChecklistStore.toggle(itemID: itemID)
        else {
            return .result()
        }

        if mutation.isCompleted {
            UNUserNotificationCenter.current().removePendingNotificationRequests(
                withIdentifiers: mutation.reminderIdentifiers
            )
        }

        return .result()
    }
}
