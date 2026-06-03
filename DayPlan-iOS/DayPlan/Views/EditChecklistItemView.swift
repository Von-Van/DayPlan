import SwiftData
import SwiftUI

struct EditChecklistItemView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let item: DailyChecklistItem
    let reminderScheduler: ReminderManaging

    @State private var title: String
    @State private var notes: String
    @State private var isPersistent: Bool
    @State private var remindersEnabled: Bool
    @State private var reminderTime: Date
    @State private var errorMessage: String?

    init(item: DailyChecklistItem, reminderScheduler: ReminderManaging) {
        self.item = item
        self.reminderScheduler = reminderScheduler
        _title = State(initialValue: item.title)
        _notes = State(initialValue: item.notes)
        _isPersistent = State(initialValue: item.isPersistent)
        _remindersEnabled = State(initialValue: !item.reminders.isEmpty)

        let schedule = item.reminders.first
        let date = Calendar.current.date(
            bySettingHour: schedule?.hour ?? 9,
            minute: schedule?.minute ?? 0,
            second: 0,
            of: Date()
        ) ?? Date()
        _reminderTime = State(initialValue: date)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Task") {
                    TextField("Title", text: $title)
                    TextField("Notes", text: $notes, axis: .vertical)
                        .lineLimit(2...5)
                }

                Section {
                    Toggle("Persist day to day", isOn: $isPersistent)
                } footer: {
                    Text("Persistent items create daily copies so previous days keep their own completion history.")
                }

                Section {
                    Toggle("Send reminder", isOn: $remindersEnabled)
                    if remindersEnabled {
                        DatePicker("Time", selection: $reminderTime, displayedComponents: .hourAndMinute)
                    }
                } footer: {
                    Text("DayPlan can only schedule reminders for its own checklist items.")
                }
            }
            .navigationTitle("Edit Task")
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
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .alert("Could not save", isPresented: .constant(errorMessage != nil), actions: {
                Button("OK") {
                    errorMessage = nil
                }
            }, message: {
                Text(errorMessage ?? "")
            })
        }
    }

    private func save() {
        do {
            try ChecklistStore.updateItem(item, title: title, notes: notes, in: modelContext)
            try ChecklistStore.setPersistence(for: item, isPersistent: isPersistent, in: modelContext)
            try updateReminder()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func updateReminder() throws {
        for schedule in item.reminders {
            reminderScheduler.cancel(schedule)
            modelContext.delete(schedule)
        }
        item.reminders.removeAll()

        guard remindersEnabled, let checklistDate = item.checklist?.date else {
            try modelContext.save()
            return
        }

        let components = Calendar.current.dateComponents([.hour, .minute], from: reminderTime)
        let schedule = ReminderSchedule(
            itemID: item.id,
            checklistDate: checklistDate,
            hour: components.hour ?? 9,
            minute: components.minute ?? 0
        )
        item.reminders.append(schedule)
        modelContext.insert(schedule)
        try modelContext.save()

        Task {
            _ = try? await reminderScheduler.requestAuthorization()
            try? await reminderScheduler.schedule(schedule, title: item.title)
        }
    }
}
