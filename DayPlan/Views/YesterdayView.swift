import SwiftData
import SwiftUI

struct YesterdayView: View {
    @Environment(\.modelContext) private var modelContext

    @State private var events: [ContentEvent] = []
    @State private var digest: DailyContentDigest?
    @State private var isLoading = false
    @State private var errorMessage: String?

    private var yesterday: Date {
        DateKeys.yesterday()
    }

    var body: some View {
        List {
            Section("Summary") {
                if isLoading {
                    ProgressView("Building digest")
                } else {
                    Text(digest?.summary ?? "No digest has been generated yet.")
                        .font(.body)
                }
            }

            if events.isEmpty && !isLoading {
                Section("Source Items") {
                    ContentUnavailableView(
                        "No content captured",
                        systemImage: "tray",
                        description: Text("The sample local adapter will seed Yesterday until real sources are added.")
                    )
                }
            } else {
                ForEach(groupedSourceNames, id: \.self) { sourceName in
                    Section(sourceName) {
                        ForEach(eventsForSource(sourceName)) { event in
                            ContentEventRow(event: event)
                        }
                    }
                }
            }
        }
        .navigationTitle("Yesterday")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task {
                        await loadDigest(forceRefresh: true)
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel("Refresh digest")
            }
        }
        .task {
            await loadDigest(forceRefresh: false)
        }
        .alert("Yesterday", isPresented: errorBinding, actions: {
            Button("OK") {
                errorMessage = nil
            }
        }, message: {
            Text(errorMessage ?? "")
        })
    }

    private var groupedSourceNames: [String] {
        Array(Set(events.map(\.sourceName))).sorted()
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    private func eventsForSource(_ sourceName: String) -> [ContentEvent] {
        events
            .filter { $0.sourceName == sourceName }
            .sorted { $0.receivedAt > $1.receivedAt }
    }

    @MainActor
    private func loadDigest(forceRefresh: Bool) async {
        isLoading = true
        defer { isLoading = false }

        do {
            try await ContentIngestionService.ingestYesterdaySampleIfNeeded(in: modelContext)
            digest = try DailyDigestBuilder.digest(for: yesterday, in: modelContext)
            events = try ContentIngestionService.fetchEvents(
                from: DateKeys.startOfDay(yesterday),
                until: DateKeys.dayAfter(yesterday),
                in: modelContext
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct ContentEventRow: View {
    let event: ContentEvent

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(event.title)
                    .font(.headline)
                Spacer()
                Text(DisplayFormatters.time.string(from: event.receivedAt))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(event.body)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Label(event.category.displayName, systemImage: iconName(for: event.category))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
    }

    private func iconName(for category: ContentCategory) -> String {
        switch category {
        case .alert: "bell"
        case .message: "message"
        case .calendar: "calendar"
        case .task: "checklist"
        case .article: "doc.text"
        case .other: "tray"
        }
    }
}
