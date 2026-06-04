import SwiftData
import SwiftUI

@main
struct DayPlanApp: App {
    private let modelContainer: ModelContainer?

    init() {
        do {
            let container = try ModelContainerFactory.privateOnDevice()
            let context = ModelContext(container)
            try? WidgetChecklistSync.applyPendingMutations(in: context)
            modelContainer = container
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
