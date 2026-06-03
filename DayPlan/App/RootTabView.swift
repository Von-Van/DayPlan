import SwiftUI

struct RootTabView: View {
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
    }
}
