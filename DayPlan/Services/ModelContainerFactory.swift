import SwiftData

enum ModelContainerFactory {
    static func inMemory() throws -> ModelContainer {
        let schema = Schema(DayPlanSchema.models)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [configuration])
    }
}
