import Foundation
import UserNotifications

protocol ReminderManaging {
    func requestAuthorization() async throws -> Bool
    func notificationSettings() async -> UNNotificationSettings
    func schedule(_ schedule: ReminderSchedule, title: String) async throws
    func cancel(_ schedule: ReminderSchedule)
    func cancelAll(for item: DailyChecklistItem)
}

struct UserNotificationReminderScheduler: ReminderManaging {
    private let center = UNUserNotificationCenter.current()

    func requestAuthorization() async throws -> Bool {
        try await center.requestAuthorization(options: [.alert, .badge, .sound])
    }

    func notificationSettings() async -> UNNotificationSettings {
        await center.notificationSettings()
    }

    func schedule(_ schedule: ReminderSchedule, title: String) async throws {
        guard schedule.isEnabled else { return }

        let content = UNMutableNotificationContent()
        content.title = "Checklist reminder"
        content.body = title
        content.sound = .default
        content.userInfo = [
            "kind": "checklist-reminder",
            "itemID": schedule.itemID.uuidString,
            "date": DateKeys.dayKey(for: schedule.checklistDate)
        ]

        var dateComponents = Calendar.current.dateComponents(
            [.year, .month, .day],
            from: schedule.checklistDate
        )
        dateComponents.hour = schedule.hour
        dateComponents.minute = schedule.minute

        let trigger = UNCalendarNotificationTrigger(dateMatching: dateComponents, repeats: false)
        let request = UNNotificationRequest(
            identifier: schedule.notificationIdentifier,
            content: content,
            trigger: trigger
        )

        try await center.add(request)
    }

    func cancel(_ schedule: ReminderSchedule) {
        center.removePendingNotificationRequests(withIdentifiers: [schedule.notificationIdentifier])
    }

    func cancelAll(for item: DailyChecklistItem) {
        center.removePendingNotificationRequests(
            withIdentifiers: item.reminders.map(\.notificationIdentifier)
        )
    }
}

struct PreviewReminderScheduler: ReminderManaging {
    func requestAuthorization() async throws -> Bool { true }

    func notificationSettings() async -> UNNotificationSettings {
        await UNUserNotificationCenter.current().notificationSettings()
    }

    func schedule(_ schedule: ReminderSchedule, title: String) async throws {}

    func cancel(_ schedule: ReminderSchedule) {}

    func cancelAll(for item: DailyChecklistItem) {}
}
