import SwiftData
import SwiftUI

struct ByDayView: View {
    @Environment(\.modelContext) private var modelContext

    @State private var selectedDate = Date()
    @State private var checklist: DailyChecklist?
    @State private var newItemTitle = ""
    @State private var editingItem: DailyChecklistItem?
    @State private var errorMessage: String?

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
        .sheet(item: $editingItem) { item in
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
        .task {
            loadChecklist()
        }
        .onChange(of: selectedDate) {
            loadChecklist()
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

    private func addItem() {
        let title = newItemTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, let checklist else { return }

        do {
            _ = try ChecklistStore.addItem(title: title, to: checklist, in: modelContext)
            newItemTitle = ""
            loadChecklist()
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
            loadChecklist()
        } catch {
            errorMessage = error.localizedDescription
        }
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
