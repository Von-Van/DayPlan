import SwiftUI

private enum DayPlanMacRoute: String, CaseIterable, Hashable, Identifiable {
    case goals
    case byDay
    case collections
    case yesterday
    case stats
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .goals: "Goals"
        case .byDay: "By Day"
        case .collections: "Collections"
        case .yesterday: "Yesterday"
        case .stats: "Stats"
        case .settings: "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .goals: "scope"
        case .byDay: "checklist"
        case .collections: "tray.full"
        case .yesterday: "newspaper"
        case .stats: "chart.bar.doc.horizontal"
        case .settings: "gearshape"
        }
    }
}

struct DayPlanMacRootView: View {
    @State private var selectedRoute: DayPlanMacRoute? = .goals

    var body: some View {
        NavigationSplitView {
            List(DayPlanMacRoute.allCases, selection: $selectedRoute) { route in
                Label(route.title, systemImage: route.systemImage)
                    .tag(route)
            }
            .navigationTitle("DayPlan")
            .frame(minWidth: 180)
        } detail: {
            switch selectedRoute ?? .goals {
            case .goals:
                GoalsWorkspaceView()
            case .byDay:
                NavigationStack {
                    ByDayView()
                }
            case .collections:
                NavigationStack {
                    CollectionsView()
                }
            case .yesterday:
                NavigationStack {
                    YesterdayView()
                }
            case .stats:
                NavigationStack {
                    StatsView()
                }
            case .settings:
                NavigationStack {
                    SettingsView()
                }
            }
        }
    }
}
