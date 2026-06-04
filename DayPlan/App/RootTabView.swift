import SwiftData
import SwiftUI

struct RootTabView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase

    @State private var widgetSyncError: String?

    var body: some View {
        TabView {
            NavigationStack {
                ByDayView()
            }
            .tabItem {
                Label("By Day", systemImage: "checklist")
            }

            NavigationStack {
                CollectionsView()
            }
            .tabItem {
                Label("Collections", systemImage: "tray.full")
            }

            NavigationStack {
                YesterdayView()
            }
            .tabItem {
                Label("Yesterday", systemImage: "newspaper")
            }

            NavigationStack {
                SettingsView()
            }
            .tabItem {
                Label("Settings", systemImage: "gearshape")
            }
        }
        .task {
            applyWidgetChanges()
        }
        .onChange(of: scenePhase) {
            if scenePhase == .active {
                applyWidgetChanges()
            }
        }
        .alert("Could not sync widget changes", isPresented: .constant(widgetSyncError != nil)) {
            Button("OK") {
                widgetSyncError = nil
            }
        } message: {
            Text(widgetSyncError ?? "")
        }
    }

    private func applyWidgetChanges() {
        do {
            try WidgetChecklistSync.applyPendingMutations(in: modelContext)
        } catch {
            widgetSyncError = error.localizedDescription
        }
    }
}
