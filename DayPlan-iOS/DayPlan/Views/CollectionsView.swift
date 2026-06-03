import SwiftData
import SwiftUI

struct CollectionsView: View {
    @Environment(\.modelContext) private var modelContext

    @Query(sort: \CollectionList.createdAt, order: .reverse)
    private var collections: [CollectionList]

    @State private var showingNewCollection = false

    var body: some View {
        List {
            if collections.isEmpty {
                ContentUnavailableView(
                    "No collections yet",
                    systemImage: "tray.full",
                    description: Text("Create a collection for non-date-bound tasks.")
                )
            } else {
                ForEach(collections) { collection in
                    NavigationLink {
                        CollectionDetailView(collection: collection)
                    } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(collection.name)
                                .font(.headline)

                            if !collection.details.isEmpty {
                                Text(collection.details)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }

                            ProgressView(
                                value: Double(collection.completedCount),
                                total: Double(max(collection.items.count, 1))
                            ) {
                                Text("\(collection.completedCount) of \(collection.items.count) complete")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 6)
                    }
                    .swipeActions {
                        Button(role: .destructive) {
                            modelContext.delete(collection)
                            try? modelContext.save()
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
        }
        .navigationTitle("Collections")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingNewCollection = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("New collection")
            }
        }
        .sheet(isPresented: $showingNewCollection) {
            NewCollectionView()
                .presentationDetents([.medium])
        }
    }
}

private struct NewCollectionView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var name = ""
    @State private var details = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField("Collection name", text: $name)
                TextField("Description", text: $details, axis: .vertical)
                    .lineLimit(2...4)
            }
            .navigationTitle("New Collection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        let collection = CollectionList(
                            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                            details: details
                        )
                        modelContext.insert(collection)
                        try? modelContext.save()
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
