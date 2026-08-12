import SwiftData
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext

    @Query(sort: \ContentSource.name)
    private var sources: [ContentSource]

    @State private var notificationStatus = "Not checked"
    @State private var errorMessage: String?
    @State private var isAddingSource = false
    @State private var editingSource: ContentSource?
    @State private var dismissedSuggestionCount = 0
    @State private var isConfirmingDismissedClear = false
    @State private var exportDocument = DayPlanArchiveDocument()
    @State private var isExportingArchive = false
    @State private var isImportingArchive = false
    @State private var pendingImportData: Data?
    @State private var isConfirmingImport = false

    private let reminderScheduler: ReminderManaging = UserNotificationReminderScheduler()

    private var deviceName: String {
        #if os(macOS)
        "Mac"
        #else
        "iPhone"
        #endif
    }

    private var deviceSystemImage: String {
        #if os(macOS)
        "desktopcomputer"
        #else
        "iphone"
        #endif
    }

    var body: some View {
        List {
            Section("Local-First") {
                Label("All planner data stays on this \(deviceName).", systemImage: deviceSystemImage)
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
                Text("Reminders use local notifications scheduled by DayPlan for DayPlan checklist items.")
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
                NavigationLink {
                    StatsView()
                } label: {
                    Label("Completion Stats", systemImage: "chart.line.uptrend.xyaxis")
                }
            }

            Section("Suggestions") {
                NavigationLink {
                    SuggestionControlsView()
                } label: {
                    Label("Source Controls", systemImage: "slider.horizontal.3")
                }

                Button(role: .destructive) {
                    isConfirmingDismissedClear = true
                } label: {
                    Label(
                        "Clear Dismissed Suggestions (\(dismissedSuggestionCount))",
                        systemImage: "arrow.counterclockwise"
                    )
                }
                .disabled(dismissedSuggestionCount == 0)
            }

            Section("Data Tools") {
                Button {
                    exportArchive()
                } label: {
                    Label("Export JSON Backup", systemImage: "square.and.arrow.up")
                }

                Button {
                    isImportingArchive = true
                } label: {
                    Label("Import JSON Backup", systemImage: "square.and.arrow.down")
                }
            }
        }
        .navigationTitle("Settings")
        .task {
            await refreshNotificationStatus()
            refreshDismissedSuggestionCount()
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
        .confirmationDialog(
            "Clear dismissed suggestions?",
            isPresented: $isConfirmingDismissedClear,
            titleVisibility: .visible
        ) {
            Button("Clear Dismissed Suggestions", role: .destructive) {
                clearDismissedSuggestions()
            }
        } message: {
            Text("Accepted suggestions stay excluded so existing checklist items are not suggested again.")
        }
        .confirmationDialog(
            "Replace local DayPlan data?",
            isPresented: $isConfirmingImport,
            titleVisibility: .visible
        ) {
            Button("Replace Local Data", role: .destructive) {
                importPendingArchive()
            }
        } message: {
            Text("This imports the selected backup and replaces the current local planner data on this device.")
        }
        .fileExporter(
            isPresented: $isExportingArchive,
            document: exportDocument,
            contentType: .json,
            defaultFilename: "DayPlan Backup \(DateKeys.dayKey(for: .now))"
        ) { result in
            if case let .failure(error) = result {
                errorMessage = error.localizedDescription
            }
        }
        .fileImporter(
            isPresented: $isImportingArchive,
            allowedContentTypes: [.json]
        ) { result in
            prepareImport(result)
        }
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

    private func refreshDismissedSuggestionCount() {
        do {
            dismissedSuggestionCount = try ContentSuggestionService.dismissedDecisionCount(in: modelContext)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func clearDismissedSuggestions() {
        do {
            try ContentSuggestionService.clearDismissedDecisions(in: modelContext)
            refreshDismissedSuggestionCount()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func exportArchive() {
        do {
            exportDocument = DayPlanArchiveDocument(
                data: try DataArchiveService.exportData(in: modelContext)
            )
            isExportingArchive = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func prepareImport(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            let canAccess = url.startAccessingSecurityScopedResource()
            defer {
                if canAccess {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            pendingImportData = try Data(contentsOf: url)
            isConfirmingImport = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func importPendingArchive() {
        guard let pendingImportData else { return }
        do {
            try DataArchiveService.replaceData(with: pendingImportData, in: modelContext)
            self.pendingImportData = nil
            refreshDismissedSuggestionCount()
            errorMessage = "Import complete."
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

private struct SuggestionControlsView: View {
    @Query(sort: \ContentSource.name)
    private var sources: [ContentSource]

    var body: some View {
        List {
            if sources.isEmpty {
                ContentUnavailableView(
                    "No content sources",
                    systemImage: "slider.horizontal.3",
                    description: Text("Add a Yesterday source before adjusting suggestion controls.")
                )
            } else {
                ForEach(sources) { source in
                    NavigationLink {
                        SuggestionRuleEditorView(source: source)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(source.name)
                            Text(source.identifier)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Suggestion Sources")
    }
}

private struct SuggestionRuleEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let source: ContentSource

    @State private var isEnabled = true
    @State private var priority: ContentSuggestionSourcePriority = .normal
    @State private var includeKeywordsString = ""
    @State private var excludeKeywordsString = ""
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section {
                Toggle("Use for suggestions", isOn: $isEnabled)

                Picker("Priority", selection: $priority) {
                    ForEach(ContentSuggestionSourcePriority.allCases) { priority in
                        Text(priority.displayName).tag(priority)
                    }
                }
            } header: {
                Text(source.name)
            } footer: {
                Text("Priority nudges the deterministic score without changing the original Yesterday item.")
            }

            Section {
                TextField("Include keywords", text: $includeKeywordsString)
                    .dayPlanNoAutocapitalization()
                TextField("Exclude keywords", text: $excludeKeywordsString)
                    .dayPlanNoAutocapitalization()
            } header: {
                Text("Suggestion Keywords")
            } footer: {
                Text("Leave include keywords empty to allow every item from this source. Exclude keywords always win.")
            }
        }
        .navigationTitle("Suggestion Rules")
        .dayPlanInlineNavigationTitle()
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    save()
                }
            }
        }
        .onAppear(perform: load)
        .alert("Suggestion Rules", isPresented: .constant(errorMessage != nil), actions: {
            Button("OK") {
                errorMessage = nil
            }
        }, message: {
            Text(errorMessage ?? "")
        })
    }

    private func load() {
        do {
            guard let rule = try ContentSuggestionService.rule(
                for: source.identifier,
                in: modelContext,
                createIfMissing: false
            ) else {
                return
            }

            isEnabled = rule.isEnabled
            priority = rule.priority
            includeKeywordsString = rule.includeKeywordsString
            excludeKeywordsString = rule.excludeKeywordsString
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func save() {
        do {
            let rule = try ContentSuggestionService.rule(
                for: source.identifier,
                in: modelContext,
                createIfMissing: true
            )
            rule?.isEnabled = isEnabled
            rule?.priority = priority
            rule?.includeKeywords = keywords(from: includeKeywordsString)
            rule?.excludeKeywords = keywords(from: excludeKeywordsString)
            rule?.updatedAt = .now
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
                        .dayPlanURLKeyboard()
                        .dayPlanNoAutocapitalization()
                        .dayPlanAutocorrectionDisabled()
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
                        .dayPlanNoAutocapitalization()
                    TextField("Exclude keywords", text: $excludeKeywordsString)
                        .dayPlanNoAutocapitalization()

                    Stepper("Maximum items: \(maxItems)", value: $maxItems, in: 5...100, step: 5)
                } header: {
                    Text("Customize")
                } footer: {
                    Text("Separate keywords with commas. An item must match at least one include keyword; any exclude keyword removes it. Leave include keywords empty to accept every item.")
                }
            }
            .navigationTitle(source == nil ? "Add Source" : "Edit Source")
            .dayPlanInlineNavigationTitle()
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
