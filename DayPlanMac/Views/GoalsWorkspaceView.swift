import SwiftData
import SwiftUI

struct GoalsWorkspaceView: View {
    @Query(sort: \Goal.sortOrder)
    private var goals: [Goal]

    @State private var selectedGoalID: UUID?
    @State private var isCreatingGoal = false

    private var activeGoals: [Goal] {
        goals
            .filter { !$0.isArchived }
            .sorted {
                if $0.sortOrder == $1.sortOrder {
                    return $0.createdAt < $1.createdAt
                }
                return $0.sortOrder < $1.sortOrder
            }
    }

    private var selectedGoal: Goal? {
        activeGoals.first { $0.id == selectedGoalID } ?? activeGoals.first
    }

    var body: some View {
        HStack(spacing: 0) {
            GoalListPane(
                goals: activeGoals,
                selectedGoalID: $selectedGoalID,
                createGoal: { isCreatingGoal = true }
            )
            .frame(minWidth: 230, idealWidth: 270, maxWidth: 320)

            Divider()

            GoalDetailPane(goal: selectedGoal)
                .frame(minWidth: 360, maxWidth: .infinity)

            Divider()

            TodayPlanningPane(selectedGoal: selectedGoal)
                .frame(minWidth: 330, idealWidth: 380, maxWidth: 460)
        }
        .navigationTitle("Goals")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isCreatingGoal = true
                } label: {
                    Label("New Goal", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $isCreatingGoal) {
            NewGoalView()
        }
        .onAppear(perform: selectDefaultGoal)
        .onChange(of: activeGoals.map(\.id)) {
            selectDefaultGoal()
        }
    }

    private func selectDefaultGoal() {
        guard selectedGoalID == nil || !activeGoals.contains(where: { $0.id == selectedGoalID }) else {
            return
        }
        selectedGoalID = activeGoals.first?.id
    }
}

private struct GoalListPane: View {
    let goals: [Goal]
    @Binding var selectedGoalID: UUID?
    let createGoal: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $selectedGoalID) {
                if goals.isEmpty {
                    ContentUnavailableView(
                        "No goals yet",
                        systemImage: "scope",
                        description: Text("Create a larger outcome, then schedule smaller actions into your days.")
                    )
                    .listRowSeparator(.hidden)
                } else {
                    ForEach(goals) { goal in
                        GoalRow(goal: goal)
                            .tag(Optional(goal.id))
                    }
                }
            }
            .listStyle(.sidebar)

            Divider()

            Button(action: createGoal) {
                Label("New Goal", systemImage: "plus.circle.fill")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding(14)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

private struct GoalRow: View {
    @Environment(\.modelContext) private var modelContext

    let goal: Goal

    private var progress: GoalProgressSummary {
        (try? GoalStore.progress(for: goal, in: modelContext)) ?? GoalProgressSummary(completed: 0, total: 0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle()
                    .fill(goalColor(goal.colorName))
                    .frame(width: 9, height: 9)

                Text(goal.title)
                    .font(.headline)
                    .lineLimit(1)

                Spacer()

                Text("\(progress.percentage)%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ProgressView(
                value: Double(progress.completed),
                total: Double(max(progress.total, 1))
            )
            .tint(goalColor(goal.colorName))

            if let targetDate = goal.targetDate {
                Text("Target \(targetDate.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 6)
    }
}

private struct GoalDetailPane: View {
    @Environment(\.modelContext) private var modelContext

    let goal: Goal?

    @State private var newActionTitle = ""
    @State private var newActionNotes = ""
    @State private var newActionPriority: CollectionPriority = .none
    @State private var errorMessage: String?
    @State private var isConfirmingArchive = false

    private var progress: GoalProgressSummary {
        guard let goal else { return GoalProgressSummary(completed: 0, total: 0) }
        return (try? GoalStore.progress(for: goal, in: modelContext)) ?? GoalProgressSummary(completed: 0, total: 0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let goal {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(goal.title)
                                    .font(.largeTitle.weight(.semibold))

                                Spacer()

                                Button(role: .destructive) {
                                    isConfirmingArchive = true
                                } label: {
                                    Label("Archive", systemImage: "archivebox")
                                }
                            }

                            if !goal.details.isEmpty {
                                Text(goal.details)
                                    .font(.body)
                                    .foregroundStyle(.secondary)
                            }

                            if let targetDate = goal.targetDate {
                                Label(
                                    targetDate.formatted(date: .long, time: .omitted),
                                    systemImage: "calendar"
                                )
                                .foregroundStyle(.secondary)
                            }

                            ProgressView(
                                value: Double(progress.completed),
                                total: Double(max(progress.total, 1))
                            ) {
                                Text("\(progress.completed) of \(progress.total) linked item(s) complete")
                            } currentValueLabel: {
                                Text("\(progress.percentage)%")
                            }
                            .tint(goalColor(goal.colorName))
                        }

                        Divider()

                        VStack(alignment: .leading, spacing: 12) {
                            Text("Action Backlog")
                                .font(.title2.weight(.semibold))

                            if GoalStore.sortedActions(for: goal).isEmpty {
                                ContentUnavailableView(
                                    "No actions yet",
                                    systemImage: "checkmark.circle",
                                    description: Text("Add an action here, then schedule it into a day when it is ready.")
                                )
                                .frame(maxWidth: .infinity, minHeight: 140)
                            } else {
                                VStack(spacing: 0) {
                                    ForEach(GoalStore.sortedActions(for: goal)) { action in
                                        GoalActionRow(
                                            action: action,
                                            schedule: { schedule(action, for: .now) },
                                            toggle: { toggle(action) }
                                        )
                                        Divider()
                                    }
                                }
                            }
                        }

                        VStack(alignment: .leading, spacing: 10) {
                            Text("Add Action")
                                .font(.headline)

                            TextField("Action title", text: $newActionTitle)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit { addAction(to: goal) }

                            TextField("Notes", text: $newActionNotes, axis: .vertical)
                                .textFieldStyle(.roundedBorder)
                                .lineLimit(2...4)

                            HStack {
                                Picker("Priority", selection: $newActionPriority) {
                                    ForEach(CollectionPriority.allCases) { priority in
                                        Text(priority.displayName).tag(priority)
                                    }
                                }
                                .frame(maxWidth: 240)

                                Spacer()

                                Button {
                                    addAction(to: goal)
                                } label: {
                                    Label("Add Action", systemImage: "plus")
                                }
                                .disabled(newActionTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }
                        }
                    }
                    .padding(24)
                }
            } else {
                ContentUnavailableView(
                    "Choose a goal",
                    systemImage: "scope",
                    description: Text("Goals gather larger outcomes, actions, and the daily work attached to them.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .alert("Goals", isPresented: errorBinding, actions: {
            Button("OK") {
                errorMessage = nil
            }
        }, message: {
            Text(errorMessage ?? "")
        })
        .confirmationDialog(
            "Archive this goal?",
            isPresented: $isConfirmingArchive,
            titleVisibility: .visible
        ) {
            Button("Archive Goal", role: .destructive) {
                archiveGoal()
            }
        } message: {
            Text("Archived goals keep their actions and links but leave the active workspace.")
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    private func addAction(to goal: Goal) {
        do {
            _ = try GoalStore.addAction(
                title: newActionTitle,
                notes: newActionNotes,
                priority: newActionPriority,
                to: goal,
                in: modelContext
            )
            newActionTitle = ""
            newActionNotes = ""
            newActionPriority = .none
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func toggle(_ action: GoalAction) {
        do {
            try GoalStore.setActionCompletion(action, isCompleted: !action.isCompleted, in: modelContext)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func schedule(_ action: GoalAction, for date: Date) {
        do {
            _ = try GoalStore.schedule(action, for: date, in: modelContext)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func archiveGoal() {
        guard let goal else { return }
        do {
            try GoalStore.archive(goal, in: modelContext)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct GoalActionRow: View {
    let action: GoalAction
    let schedule: () -> Void
    let toggle: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: toggle) {
                Image(systemName: action.isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(action.isCompleted ? Color.green : Color.secondary)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 5) {
                Text(action.title)
                    .font(.headline)
                    .strikethrough(action.isCompleted)

                if !action.notes.isEmpty {
                    Text(action.notes)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }

                HStack(spacing: 8) {
                    if action.priority != .none {
                        Label(action.priority.displayName, systemImage: "flag")
                    }

                    if let scheduledDate = action.scheduledDate {
                        Label(
                            scheduledDate.formatted(date: .abbreviated, time: .omitted),
                            systemImage: "calendar.badge.checkmark"
                        )
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            Button(action: schedule) {
                Label(
                    action.scheduledChecklistItemID == nil ? "Today" : "Scheduled",
                    systemImage: "calendar.badge.plus"
                )
            }
            .disabled(action.scheduledChecklistItemID != nil)
        }
        .padding(.vertical, 10)
    }
}

private struct TodayPlanningPane: View {
    @Environment(\.modelContext) private var modelContext

    @Query(sort: \Goal.sortOrder)
    private var goals: [Goal]

    let selectedGoal: Goal?

    @State private var selectedDate = Date()
    @State private var selectedGoalID: UUID?
    @State private var checklist: DailyChecklist?
    @State private var newItemTitle = ""
    @State private var errorMessage: String?

    private var activeGoals: [Goal] {
        goals.filter { !$0.isArchived }
    }

    private var sortedItems: [DailyChecklistItem] {
        (checklist?.items ?? []).sorted {
            if $0.sortOrder == $1.sortOrder {
                return $0.createdAt < $1.createdAt
            }
            return $0.sortOrder < $1.sortOrder
        }
    }

    private var schedulableActions: [GoalAction] {
        guard let selectedGoal else { return [] }
        return GoalStore.sortedActions(for: selectedGoal)
            .filter { !$0.isCompleted && $0.scheduledChecklistItemID == nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Today")
                    .font(.title2.weight(.semibold))

                DatePicker("Plan day", selection: $selectedDate, displayedComponents: .date)
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
            }
            .padding(18)

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                TextField("Add task", text: $newItemTitle)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addItem)

                Picker("Goal", selection: $selectedGoalID) {
                    Text("No goal").tag(UUID?.none)
                    ForEach(activeGoals) { goal in
                        Text(goal.title).tag(Optional(goal.id))
                    }
                }

                Button {
                    addItem()
                } label: {
                    Label("Add to Day", systemImage: "plus")
                }
                .disabled(newItemTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(18)

            Divider()

            List {
                Section("Checklist") {
                    if sortedItems.isEmpty {
                        ContentUnavailableView(
                            "No tasks for this day",
                            systemImage: "checklist",
                            description: Text("Add a task or schedule a goal action.")
                        )
                    } else {
                        ForEach(sortedItems) { item in
                            TodayChecklistRow(
                                item: item,
                                goalTitle: goalTitle(for: item.goalID),
                                toggle: { toggle(item) }
                            )
                        }
                    }
                }

                if !schedulableActions.isEmpty {
                    Section("Schedule From Goal") {
                        ForEach(schedulableActions) { action in
                            Button {
                                schedule(action)
                            } label: {
                                Label(action.title, systemImage: "calendar.badge.plus")
                                    .lineLimit(2)
                            }
                        }
                    }
                }
            }
            .listStyle(.inset)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            selectedGoalID = selectedGoal?.id
            loadChecklist()
        }
        .onChange(of: selectedDate) {
            loadChecklist()
        }
        .onChange(of: selectedGoal?.id) {
            selectedGoalID = selectedGoal?.id
        }
        .alert("Today", isPresented: errorBinding, actions: {
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
            _ = try ChecklistStore.addItem(
                title: title,
                goalID: selectedGoalID,
                to: checklist,
                in: modelContext
            )
            newItemTitle = ""
            loadChecklist()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func toggle(_ item: DailyChecklistItem) {
        do {
            try ChecklistStore.toggleCompletion(for: item, in: modelContext)
            loadChecklist()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func schedule(_ action: GoalAction) {
        do {
            _ = try GoalStore.schedule(action, for: selectedDate, in: modelContext)
            loadChecklist()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func goalTitle(for goalID: UUID?) -> String? {
        guard let goalID else { return nil }
        return goals.first { $0.id == goalID }?.title
    }
}

private struct TodayChecklistRow: View {
    let item: DailyChecklistItem
    let goalTitle: String?
    let toggle: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button(action: toggle) {
                Image(systemName: item.isCompleted ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(item.isCompleted ? Color.green : Color.secondary)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .strikethrough(item.isCompleted)

                if let goalTitle {
                    Label(goalTitle, systemImage: item.goalActionID == nil ? "scope" : "calendar.badge.plus")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

private struct NewGoalView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var title = ""
    @State private var details = ""
    @State private var colorName = "green"
    @State private var hasTargetDate = false
    @State private var targetDate = Date()
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Goal") {
                    TextField("Title", text: $title)
                    TextField("Details", text: $details, axis: .vertical)
                        .lineLimit(2...5)
                }

                Section("Planning") {
                    Picker("Color", selection: $colorName) {
                        ForEach(goalColorNames, id: \.self) { name in
                            Label(name.capitalized, systemImage: "circle.fill")
                                .foregroundStyle(goalColor(name))
                                .tag(name)
                        }
                    }

                    Toggle("Target date", isOn: $hasTargetDate)
                    if hasTargetDate {
                        DatePicker("Date", selection: $targetDate, displayedComponents: .date)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("New Goal")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        create()
                    }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .frame(width: 460, height: 360)
        .alert("New Goal", isPresented: errorBinding, actions: {
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

    private func create() {
        do {
            _ = try GoalStore.createGoal(
                title: title,
                details: details,
                colorName: colorName,
                targetDate: hasTargetDate ? DateKeys.startOfDay(targetDate) : nil,
                in: modelContext
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private let goalColorNames = ["green", "blue", "purple", "orange", "pink", "gray"]

private func goalColor(_ name: String) -> Color {
    switch name {
    case "blue":
        return .blue
    case "purple":
        return .purple
    case "orange":
        return .orange
    case "pink":
        return .pink
    case "gray":
        return .gray
    default:
        return .green
    }
}
