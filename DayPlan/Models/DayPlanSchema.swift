import SwiftData

enum DayPlanSchema {
    static let modelsBeforeContentSuggestions: [any PersistentModel.Type] = [
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

    static let models: [any PersistentModel.Type] = modelsBeforeContentSuggestions + [
        ContentSuggestionDecision.self
    ]
}
