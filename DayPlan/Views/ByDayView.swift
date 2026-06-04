import SwiftData
import SwiftUI

struct ByDayView: View {
    @Environment(\.modelContext) private var modelContext

    @State private var selectedDate = Date()
    @State private var checklist: DailyChecklist?
    @State private var newItemTitle = ""
    @State private var editingItem: DailyChecklistItem?
    @State private var errorMessage: String?
    @State private var suggestedItem: SuggestedChecklistItem?
    @State private var didLoadSuggestion = false
    @State private var isLoadingSuggestion = false
    @State private var isProcessingSuggestion = false

    private let reminderScheduler: ReminderManaging = UserNotificationReminderScheduler()

    var body: some View {
        List {
            Section {
                DatePicker(
                    "Checklist day",
                    selection: $selectedDate,
                    displayedComponents: .date
                )
                .datePickerStyle(.compact)

                if let checklist {
                    ProgressView(
                        value: Double(checklist.completedCount),
                        total: Double(max(checklist.items.count, 1))
                    ) {
                        Text("\(checklist.completedCount) of \(checklist.items.count) complete")
                    }
                    .tint(.green)
                }
            } header: {
                Text(DisplayFormatters.dayTitle.string(from: selectedDate))
            }

            if ContentSuggestionService.supportsSuggestions(for: selectedDate) {
                Section("Suggested Item") {
                    if isLoadingSuggestion && !didLoadSuggestion {
                        ProgressView("Finding a high-priority item")
                    } else if let suggestedItem {
                        SuggestedItemRow(
                            suggestion: suggestedItem,
                            isProcessing: isProcessingSuggestion,
                            accept: acceptSuggestion,
                            dismiss: dismissSuggestion
                        )
                    } else {
                        Label(
                            "No more high-priority suggestions from yesterday.",
                            systemImage: "checkmark.seal"
                        )
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 6)
                    }
                }
            }

            Section("Checklist") {
                if let checklist {
                    if checklist.items.isEmpty {
                        ContentUnavailableView(
                            "No tasks yet",
                            systemImage: "checklist",
                            description: Text("Add a task for this day.")
                        )
                    } else {
                        ForEach(sortedItems(checklist.items)) { item in
                            ChecklistItemRow(item: item) {
                                toggle(item)
                            } edit: {
                                editingItem = item
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    delete(item)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                } else {
                    ProgressView("Loading checklist")
                }
            }

            Section {
                HStack(spacing: 12) {
                    TextField("Add checklist item", text: $newItemTitle)
                        .submitLabel(.done)
                        .onSubmit(addItem)

                    Button {
                        addItem()
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.title2)
                    }
                    .buttonStyle(.borderless)
                    .disabled(newItemTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }

            Section("Future Stats") {
                Label("Completion history is being stored for a later stats view.", systemImage: "chart.bar.doc.horizontal")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("By Day")
        .sheet(item: $editingItem, onDismiss: reloadSuggestion) { item in
            EditChecklistItemView(item: item, reminderScheduler: reminderScheduler)
                .presentationDetents([.medium, .large])
        }
        .alert("DayPlan", isPresented: .constant(errorMessage != nil), actions: {
            Button("OK") {
                errorMessage = nil
            }
        }, message: {
            Text(errorMessage ?? "")
        })
        .onAppear {
            loadChecklistAndSuggestion()
        }
        .onChange(of: selectedDate) {
            loadChecklistAndSuggestion()
        }
    }

    private func sortedItems(_ items: [DailyChecklistItem]) -> [DailyChecklistItem] {
        items.sorted {
            if $0.sortOrder == $1.sortOrder {
                return $0.createdAt < $1.createdAt
            }
            return $0.sortOrder < $1.sortOrder
        }
    }

    private func loadChecklist() {
        do {
            checklist = try ChecklistStore.checklist(for: selectedDate, in: modelContext)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadChecklistAndSuggestion() {
        loadChecklist()
        reloadSuggestion()
    }

    private func reloadSuggestion() {
        guard ContentSuggestionService.supportsSuggestions(for: selectedDate) else {
            suggestedItem = nil
            didLoadSuggestion = false
            isLoadingSuggestion = false
            return
        }

        isLoadingSuggestion = true
        defer {
            isLoadingSuggestion = false
            didLoadSuggestion = true
        }

        do {
            suggestedItem = try ContentSuggestionService.nextSuggestion(
                for: selectedDate,
                in: modelContext
            )
        } catch {
            suggestedItem = nil
            errorMessage = error.localizedDescription
        }
    }

    private func addItem() {
        let title = newItemTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, let checklist else { return }

        do {
            _ = try ChecklistStore.addItem(title: title, to: checklist, in: modelContext)
            newItemTitle = ""
            loadChecklistAndSuggestion()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func toggle(_ item: DailyChecklistItem) {
        do {
            let willComplete = !item.isCompleted
            try ChecklistStore.toggleCompletion(for: item, isCompleted: willComplete, in: modelContext)
            if willComplete {
                reminderScheduler.cancelAll(for: item)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func delete(_ item: DailyChecklistItem) {
        reminderScheduler.cancelAll(for: item)
        do {
            try ChecklistStore.deleteItem(item, in: modelContext)
            loadChecklistAndSuggestion()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func acceptSuggestion() {
        guard let suggestedItem, !isProcessingSuggestion else { return }
        isProcessingSuggestion = true
        defer { isProcessingSuggestion = false }

        do {
            _ = try ContentSuggestionService.accept(
                suggestedItem,
                for: selectedDate,
                in: modelContext
            )
            loadChecklistAndSuggestion()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func dismissSuggestion() {
        guard let suggestedItem, !isProcessingSuggestion else { return }
        isProcessingSuggestion = true
        defer { isProcessingSuggestion = false }

        do {
            try ContentSuggestionService.dismiss(suggestedItem, in: modelContext)
            reloadSuggestion()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct SuggestedItemRow: View {
    let suggestion: SuggestedChecklistItem
    let isProcessing: Bool
    let accept: () -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Label(suggestion.sourceName, systemImage: "tray.full")
                Text("|")
                Text(suggestion.category.displayName)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)

            Text(suggestion.title)
                .font(.headline)

            if !suggestion.excerpt.isEmpty {
                Text(suggestion.excerpt)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }

            Label(suggestion.reason, systemImage: "lightbulb")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button(action: dismiss) {
                    Image(systemName: "xmark.circle")
                        .font(.title2)
                        .foregroundStyle(.red)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.borderless)
                .disabled(isProcessing)
                .accessibilityLabel("Dismiss suggestion")

                if let url = suggestion.url {
                    Link(destination: url) {
                        Label("Open original", systemImage: "arrow.up.right.square")
                            .font(.subheadline)
                    }
                }

                Spacer()

                Button(action: accept) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.green)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.borderless)
                .disabled(isProcessing)
                .accessibilityLabel("Add suggestion to today's checklist")
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }
}

private struct ChecklistItemRow: View {
    let item: DailyChecklistItem
    let toggle: () -> Void
    let edit: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: toggle) {
                Image(systemName: item.isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(item.isCompleted ? .green : .secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(item.isCompleted ? "Mark incomplete" : "Mark complete")

            VStack(alignment: .leading, spacing: 5) {
                Text(item.title)
                    .strikethrough(item.isCompleted)
                    .foregroundStyle(item.isCompleted ? .secondary : .primary)
                    .font(.body)

                HStack(spacing: 8) {
                    if item.isPersistent {
                        Label("Daily", systemImage: "repeat")
                    }
                    if !item.reminders.isEmpty {
                        Label("Reminder", systemImage: "bell")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Button(action: edit) {
                Image(systemName: "slider.horizontal.3")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Edit \(item.title)")
        }
        .padding(.vertical, 6)
    }
}
