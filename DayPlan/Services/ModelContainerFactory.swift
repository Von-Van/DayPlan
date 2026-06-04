import SwiftData

enum ModelContainerFactory {
    static func privateOnDevice() throws -> ModelContainer {
        let schema = Schema(DayPlanSchema.models)
        let configuration = privateConfiguration(schema: schema)
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    static func privateConfiguration(schema: Schema) -> ModelConfiguration {
        ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false,
            groupContainer: .none,
            cloudKitDatabase: .none
        )
    }

    static func inMemory() throws -> ModelContainer {
        let schema = Schema(DayPlanSchema.models)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [configuration])
    }
}
