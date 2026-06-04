import SwiftUI
import WidgetKit

struct DayPlanChecklistEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetChecklistSnapshot?
}

struct DayPlanChecklistProvider: TimelineProvider {
    func placeholder(in context: Context) -> DayPlanChecklistEntry {
        DayPlanChecklistEntry(date: .now, snapshot: Self.placeholderSnapshot)
    }

    func getSnapshot(
        in context: Context,
        completion: @escaping (DayPlanChecklistEntry) -> Void
    ) {
        let snapshot = context.isPreview
            ? Self.placeholderSnapshot
            : WidgetChecklistStore.snapshot()
        completion(DayPlanChecklistEntry(date: .now, snapshot: snapshot))
    }

    func getTimeline(
        in context: Context,
        completion: @escaping (Timeline<DayPlanChecklistEntry>) -> Void
    ) {
        let now = Date.now
        let entry = DayPlanChecklistEntry(date: now, snapshot: WidgetChecklistStore.snapshot(for: now))
        let nextDay = Calendar.current.date(
            byAdding: .day,
            value: 1,
            to: Calendar.current.startOfDay(for: now)
        ) ?? now.addingTimeInterval(3_600)
        completion(Timeline(entries: [entry], policy: .after(nextDay)))
    }

    private static let placeholderSnapshot = WidgetChecklistSnapshot(
        dayKey: WidgetChecklistStore.dayKey(for: .now),
        generatedAt: .now,
        items: [
            WidgetChecklistItem(
                id: UUID(),
                title: "Plan the day",
                isCompleted: true,
                sortOrder: 0,
                reminderIdentifiers: []
            ),
            WidgetChecklistItem(
                id: UUID(),
                title: "Take a walk",
                isCompleted: false,
                sortOrder: 1,
                reminderIdentifiers: []
            )
        ]
    )
}

struct DayPlanChecklistWidgetView: View {
    @Environment(\.widgetFamily) private var family

    let entry: DayPlanChecklistEntry

    var body: some View {
        switch family {
        case .accessoryRectangular:
            accessoryRectangularView
        default:
            systemMediumView
        }
    }

    private var accessoryRectangularView: some View {
        VStack(alignment: .leading, spacing: 2) {
            header
                .font(.caption2.weight(.semibold))

            if visibleItems.isEmpty {
                Text("Open DayPlan to prepare today")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            } else {
                ForEach(visibleItems.prefix(2)) { item in
                    checklistButton(item, font: .caption2)
                }
            }
        }
    }

    private var systemMediumView: some View {
        VStack(alignment: .leading, spacing: 7) {
            header
                .font(.headline)

            if visibleItems.isEmpty {
                ContentUnavailableView(
                    "Today's checklist is ready in DayPlan",
                    systemImage: "checklist"
                )
            } else {
                ForEach(visibleItems.prefix(4)) { item in
                    checklistButton(item, font: .subheadline)
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 5) {
            Image(systemName: "checklist")
                .widgetAccentable()
            Text("Today")
            Spacer(minLength: 4)
            Text("\(completedCount)/\(totalCount)")
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    private func checklistButton(_ item: WidgetChecklistItem, font: Font) -> some View {
        Button(intent: ToggleChecklistItemIntent(itemID: item.id)) {
            HStack(spacing: 5) {
                Image(systemName: item.isCompleted ? "checkmark.circle.fill" : "circle")
                    .widgetAccentable()
                Text(item.title)
                    .strikethrough(item.isCompleted)
                    .lineLimit(1)
                    .privacySensitive()
                Spacer(minLength: 0)
            }
            .font(font)
            .foregroundStyle(item.isCompleted ? .secondary : .primary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.isCompleted ? "Mark \(item.title) incomplete" : "Mark \(item.title) complete")
    }

    private var visibleItems: [WidgetChecklistItem] {
        guard let items = entry.snapshot?.items else { return [] }
        return items.filter { !$0.isCompleted } + items.filter(\.isCompleted)
    }

    private var completedCount: Int {
        entry.snapshot?.completedCount ?? 0
    }

    private var totalCount: Int {
        entry.snapshot?.items.count ?? 0
    }
}

struct DayPlanChecklistWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: WidgetChecklistStore.widgetKind,
            provider: DayPlanChecklistProvider()
        ) { entry in
            DayPlanChecklistWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Today's Checklist")
        .description("Check off today's DayPlan items from the Lock Screen.")
        .supportedFamilies([.accessoryRectangular, .systemMedium])
    }
}

@main
struct DayPlanWidgetBundle: WidgetBundle {
    var body: some Widget {
        DayPlanChecklistWidget()
    }
}
