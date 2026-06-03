import SwiftData
import SwiftUI

@main
struct DayPlanApp: App {
    private let modelContainer: ModelContainer

    init() {
        let schema = Schema(DayPlanSchema.models)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            modelContainer = try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("Failed to create DayPlan model container: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            RootTabView()
        }
        .modelContainer(modelContainer)
    }
}
