import SwiftData
import SwiftUI

@main
struct DayPlanApp: App {
    private let modelContainer: ModelContainer?

    init() {
        let schema = Schema(DayPlanSchema.models)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            modelContainer = try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            modelContainer = nil
        }
    }

    var body: some Scene {
        WindowGroup {
            if let modelContainer {
                RootTabView()
                    .modelContainer(modelContainer)
            } else {
                ContentUnavailableView(
                    "DayPlan could not open its data",
                    systemImage: "externaldrive.badge.exclamationmark",
                    description: Text("Your local data was left untouched. Restart the app, and use a backup before resetting or reinstalling.")
                )
            }
        }
    }
}
