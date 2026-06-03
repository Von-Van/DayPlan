import SwiftData

enum DayPlanSchema {
    static let models: [any PersistentModel.Type] = [
        ChecklistTemplateItem.self,
        DailyChecklist.self,
        DailyChecklistItem.self,
        ReminderSchedule.self,
        CollectionList.self,
        CollectionItem.self,
        ContentSource.self,
        ContentEvent.self,
        DailyContentDigest.self
    ]
}
