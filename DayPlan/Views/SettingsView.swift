import SwiftData
import SwiftUI
import UserNotifications

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext

    @Query(sort: \ContentSource.name)
    private var sources: [ContentSource]

    @State private var notificationStatus = "Not checked"
    @State private var errorMessage: String?
    @State private var isAddingSource = false
    @State private var editingSource: ContentSource?

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
                    ContentUnavailableView(
                        "No content sources",
                        systemImage: "dot.radiowaves.left.and.right",
                        description: Text("Add an RSS or Atom feed to fill Yesterday with content you choose.")
                    )
                } else {
                    ForEach(sources) { source in
                        sourceRow(source)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    deleteSource(source)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }

                                if source.kind == .rss {
                                    Button {
                                        editingSource = source
                                    } label: {
                                        Label("Edit", systemImage: "pencil")
                                    }
                                    .tint(.blue)
                                }
                            }
                    }
                }

                Button {
                    isAddingSource = true
                } label: {
                    Label("Add RSS or Atom Feed", systemImage: "plus")
                }
            } header: {
                Text("Yesterday Sources")
            } footer: {
                Text("RSS and Atom feeds are fetched directly over HTTPS. Include and exclude keywords decide which feed items enter Yesterday.")
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
        .sheet(isPresented: $isAddingSource) {
            ContentSourceEditorView()
        }
        .sheet(item: $editingSource) { source in
            ContentSourceEditorView(source: source)
        }
        .alert("Settings", isPresented: errorBinding, actions: {
            Button("OK") {
                errorMessage = nil
            }
        }, message: {
            Text(errorMessage ?? "")
        })
    }

    @ViewBuilder
    private func sourceRow(_ source: ContentSource) -> some View {
        Toggle(isOn: binding(for: source)) {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Label(source.name, systemImage: source.kind == .rss ? "dot.radiowaves.left.and.right" : "shippingbox")
                        .font(.body)

                    Text(source.kind.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let endpoint = source.endpointURLString,
                   let host = URL(string: endpoint)?.host {
                    Text(host)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let error = source.lastErrorMessage {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                } else if let lastFetchedAt = source.lastFetchedAt {
                    Text("Updated \(lastFetchedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if source.kind == .rss {
                    editingSource = source
                }
            }
        }
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
                do {
                    try modelContext.save()
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        )
    }

    private func deleteSource(_ source: ContentSource) {
        modelContext.delete(source)
        do {
            try modelContext.save()
        } catch {
            errorMessage = error.localizedDescription
        }
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

private struct ContentSourceEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let source: ContentSource?

    @State private var name: String
    @State private var endpointURLString: String
    @State private var category: ContentCategory
    @State private var includeKeywordsString: String
    @State private var excludeKeywordsString: String
    @State private var maxItems: Int
    @State private var errorMessage: String?

    init(source: ContentSource? = nil) {
        self.source = source
        _name = State(initialValue: source?.name ?? "")
        _endpointURLString = State(initialValue: source?.endpointURLString ?? "")
        _category = State(initialValue: source?.defaultCategory ?? .article)
        _includeKeywordsString = State(initialValue: source?.includeKeywordsString ?? "")
        _excludeKeywordsString = State(initialValue: source?.excludeKeywordsString ?? "")
        _maxItems = State(initialValue: source?.maxItemsPerRefresh ?? 30)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Source name", text: $name)
                    TextField("https://example.com/feed.xml", text: $endpointURLString)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Feed")
                } footer: {
                    Text("Only public HTTPS RSS and Atom URLs are accepted.")
                }

                Section {
                    Picker("Category", selection: $category) {
                        ForEach(ContentCategory.allCases) { category in
                            Text(category.displayName).tag(category)
                        }
                    }

                    TextField("Include keywords", text: $includeKeywordsString)
                        .textInputAutocapitalization(.never)
                    TextField("Exclude keywords", text: $excludeKeywordsString)
                        .textInputAutocapitalization(.never)

                    Stepper("Maximum items: \(maxItems)", value: $maxItems, in: 5...100, step: 5)
                } header: {
                    Text("Customize")
                } footer: {
                    Text("Separate keywords with commas. An item must match at least one include keyword; any exclude keyword removes it. Leave include keywords empty to accept every item.")
                }
            }
            .navigationTitle(source == nil ? "Add Source" : "Edit Source")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .alert("Content Source", isPresented: errorBinding, actions: {
                Button("OK") {
                    errorMessage = nil
                }
            }, message: {
                Text(errorMessage ?? "")
            })
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    private func save() {
        do {
            let cleanName = String(
                name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80)
            )
            guard !cleanName.isEmpty else {
                throw SourceEditorError.nameRequired
            }
            let endpointURL = try FeedURLPolicy.validatedPublicHTTPSURL(from: endpointURLString)
            let includeKeywords = keywords(from: includeKeywordsString)
            let excludeKeywords = keywords(from: excludeKeywordsString)

            if let source {
                source.name = cleanName
                source.kind = .rss
                source.endpointURLString = endpointURL.absoluteString
                source.defaultCategory = category
                source.includeKeywords = includeKeywords
                source.excludeKeywords = excludeKeywords
                source.maxItemsPerRefresh = maxItems
                source.lastErrorMessage = nil
                source.updatedAt = .now
            } else {
                let newSource = ContentSource(
                    identifier: "rss.\(UUID().uuidString.lowercased())",
                    name: cleanName,
                    kind: .rss,
                    endpointURLString: endpointURL.absoluteString,
                    defaultCategory: category,
                    includeKeywords: includeKeywords,
                    excludeKeywords: excludeKeywords,
                    maxItemsPerRefresh: maxItems
                )
                modelContext.insert(newSource)
            }

            try modelContext.save()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func keywords(from value: String) -> [String] {
        value
            .split(separator: ",")
            .prefix(20)
            .map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(64)) }
            .filter { !$0.isEmpty }
    }
}

private enum SourceEditorError: LocalizedError {
    case nameRequired

    var errorDescription: String? {
        "Enter a source name."
    }
}
