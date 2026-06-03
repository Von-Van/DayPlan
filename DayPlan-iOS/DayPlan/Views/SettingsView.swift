import SwiftData
import SwiftUI
import UserNotifications

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext

    @Query(sort: \ContentSource.name)
    private var sources: [ContentSource]

    @State private var notificationStatus = "Not checked"
    @State private var errorMessage: String?

    private let reminderScheduler: ReminderManaging = UserNotificationReminderScheduler()

    var body: some View {
        List {
            Section("Local-First") {
                Label("All planner data stays on this iPhone.", systemImage: "iphone")
                Label("No account, server, or cloud sync is used.", systemImage: "lock")
                Label("Other apps' Notification Center alerts are not scraped.", systemImage: "hand.raised")
            }

            Section {
                HStack {
                    Text("Permission")
                    Spacer()
                    Text(notificationStatus)
                        .foregroundStyle(.secondary)
                }

                Button("Request Reminder Permission") {
                    Task {
                        await requestNotifications()
                    }
                }
            } header: {
                Text("Notifications")
            } footer: {
                Text("Reminders use iOS local notifications scheduled by DayPlan for DayPlan checklist items.")
            }

            Section {
                if sources.isEmpty {
                    Text("Open Yesterday once to install the sample local source.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(sources) { source in
                        Toggle(source.name, isOn: binding(for: source))
                    }
                }
            } header: {
                Text("Content Sources")
            } footer: {
                Text("V1 includes a source-adapter shell and sample local source. Real integrations can be added later without changing the Yesterday UI.")
            }

            Section("Stats") {
                Label("Completion history is stored now; charts come later.", systemImage: "chart.line.uptrend.xyaxis")
                    .foregroundStyle(.secondary)
            }

            Section("Data Tools") {
                Label("Local export/import will be added after the v1 model settles.", systemImage: "square.and.arrow.up")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Settings")
        .task {
            await refreshNotificationStatus()
        }
        .alert("Settings", isPresented: errorBinding, actions: {
            Button("OK") {
                errorMessage = nil
            }
        }, message: {
            Text(errorMessage ?? "")
        })
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    private func binding(for source: ContentSource) -> Binding<Bool> {
        Binding(
            get: { source.isEnabled },
            set: { value in
                source.isEnabled = value
                source.updatedAt = .now
                try? modelContext.save()
            }
        )
    }

    @MainActor
    private func requestNotifications() async {
        do {
            _ = try await reminderScheduler.requestAuthorization()
            await refreshNotificationStatus()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func refreshNotificationStatus() async {
        let settings = await reminderScheduler.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized:
            notificationStatus = "Allowed"
        case .denied:
            notificationStatus = "Denied"
        case .notDetermined:
            notificationStatus = "Not requested"
        case .provisional:
            notificationStatus = "Provisional"
        case .ephemeral:
            notificationStatus = "Ephemeral"
        @unknown default:
            notificationStatus = "Unknown"
        }
    }
}
