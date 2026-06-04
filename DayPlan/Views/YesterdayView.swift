import SwiftData
import SwiftUI

struct YesterdayView: View {
    @Environment(\.modelContext) private var modelContext

    @State private var events: [ContentEvent] = []
    @State private var digest: DailyContentDigest?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var refreshReport: ContentRefreshReport?

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

                    if let refreshReport {
                        Text(refreshDescription(for: refreshReport))
                            .font(.caption)
                            .foregroundStyle(refreshReport.hasFailures ? Color.orange : Color.secondary)
                    }
                }
            }

            if events.isEmpty && !isLoading {
                Section("Source Items") {
                    ContentUnavailableView(
                        "No content captured",
                        systemImage: "tray",
                        description: Text("Add or enable RSS and Atom sources in Settings, then refresh Yesterday.")
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
                        await loadDigest()
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel("Refresh digest")
            }
        }
        .task {
            await loadDigest()
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
    private func loadDigest() async {
        isLoading = true
        defer { isLoading = false }

        do {
            refreshReport = try await ContentIngestionService.refreshYesterday(in: modelContext)
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

    private func refreshDescription(for report: ContentRefreshReport) -> String {
        let refreshed = "\(report.refreshedSourceCount) source(s) refreshed"
        let imported = "\(report.importedItemCount) new item(s)"
        guard report.hasFailures else {
            return "\(refreshed) | \(imported)"
        }

        let failures = report.failures
            .map { "\($0.sourceName): \($0.message)" }
            .joined(separator: " ")
        return "\(refreshed) | \(imported) | \(failures)"
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

            if let url = eventURL {
                Link(destination: url) {
                    Label("Open item", systemImage: "arrow.up.right.square")
                        .font(.caption)
                }
            }
        }
        .padding(.vertical, 6)
    }

    private var eventURL: URL? {
        guard let urlString = event.urlString,
              let url = URL(string: urlString),
              FeedURLPolicy.isAllowed(url)
        else {
            return nil
        }
        return url
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
