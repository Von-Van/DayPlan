import SwiftData

enum DayPlanSchema {
    static let modelsBeforeContentSuggestions: [any PersistentModel.Type] = [
        ChecklistTemplateItem.self,
        DailyChecklist.self,
        DailyChecklistItem.self,
        ReminderSchedule.self,
        CollectionList.self,
        CollectionItem.self,
        Goal.self,
        GoalAction.self,
        ContentSource.self,
        ContentEvent.self,
        DailyContentDigest.self
    ]

    static let models: [any PersistentModel.Type] = modelsBeforeContentSuggestions + [
        ContentSuggestionDecision.self,
        ContentSuggestionSourceRule.self
    ]
}
