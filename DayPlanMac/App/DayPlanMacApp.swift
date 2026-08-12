import SwiftData
import SwiftUI

@main
struct DayPlanMacApp: App {
    private let modelContainer: ModelContainer?

    init() {
        do {
            modelContainer = try ModelContainerFactory.privateOnDevice()
        } catch {
            modelContainer = nil
        }
    }

    var body: some Scene {
        WindowGroup {
            if let modelContainer {
                DayPlanMacRootView()
                    .modelContainer(modelContainer)
                    .frame(minWidth: 980, minHeight: 660)
            } else {
                ContentUnavailableView(
                    "DayPlan could not open its data",
                    systemImage: "externaldrive.badge.exclamationmark",
                    description: Text("Your local data was left untouched. Restart the app, and use a backup before resetting or reinstalling.")
                )
                .frame(minWidth: 600, minHeight: 360)
            }
        }
        .windowResizability(.contentSize)
        .commands {
            SidebarCommands()
        }
    }
}
