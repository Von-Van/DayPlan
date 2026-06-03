import SwiftData
import SwiftUI

struct CollectionDetailView: View {
    @Environment(\.modelContext) private var modelContext

    let collection: CollectionList

    @State private var newItemTitle = ""
    @State private var priority: CollectionPriority = .none

    var body: some View {
        List {
            Section {
                if !collection.details.isEmpty {
                    Text(collection.details)
                        .foregroundStyle(.secondary)
                }

                ProgressView(
                    value: Double(collection.completedCount),
                    total: Double(max(collection.items.count, 1))
                ) {
                    Text("\(collection.completedCount) of \(collection.items.count) complete")
                }
                .tint(.green)
            }

            Section("Tasks") {
                if collection.items.isEmpty {
                    ContentUnavailableView(
                        "No tasks",
                        systemImage: "checkmark.circle",
                        description: Text("Add a task to this collection.")
                    )
                } else {
                    ForEach(sortedItems) { item in
                        HStack(spacing: 12) {
                            Button {
                                toggle(item)
                            } label: {
                                Image(systemName: item.isCompleted ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(item.isCompleted ? .green : .secondary)
                            }
                            .buttonStyle(.plain)

                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.title)
                                    .strikethrough(item.isCompleted)
                                if item.priority != .none {
                                    Text(item.priority.displayName)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }

                            Spacer()
                        }
                        .padding(.vertical, 4)
                        .swipeActions {
                            Button(role: .destructive) {
                                modelContext.delete(item)
                                try? modelContext.save()
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
            }

            Section {
                TextField("Add collection task", text: $newItemTitle)
                    .submitLabel(.done)
                    .onSubmit(addItem)

                Picker("Priority", selection: $priority) {
                    ForEach(CollectionPriority.allCases) { priority in
                        Text(priority.displayName).tag(priority)
                    }
                }

                Button("Add Task", action: addItem)
                    .disabled(newItemTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .navigationTitle(collection.name)
    }

    private var sortedItems: [CollectionItem] {
        collection.items.sorted {
            if $0.sortOrder == $1.sortOrder {
                return $0.createdAt < $1.createdAt
            }
            return $0.sortOrder < $1.sortOrder
        }
    }

    private func addItem() {
        let title = newItemTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }

        let item = CollectionItem(
            title: title,
            priority: priority,
            sortOrder: collection.items.count,
            collection: collection
        )
        collection.items.append(item)
        collection.updatedAt = .now
        modelContext.insert(item)
        try? modelContext.save()
        newItemTitle = ""
        priority = .none
    }

    private func toggle(_ item: CollectionItem) {
        item.isCompleted.toggle()
        item.completedAt = item.isCompleted ? .now : nil
        item.updatedAt = .now
        collection.updatedAt = .now
        try? modelContext.save()
    }
}
