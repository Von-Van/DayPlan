import SwiftData
import SwiftUI

struct StatsView: View {
    @Environment(\.modelContext) private var modelContext

    @State private var summary: CompletionStatsSummary?
    @State private var errorMessage: String?

    var body: some View {
        List {
            if let summary {
                Section("Daily Checklist") {
                    StatsMetricRow(title: "Today", metric: summary.today, systemImage: "sun.max")
                    StatsMetricRow(title: "Last 7 Days", metric: summary.lastSevenDays, systemImage: "calendar")
                    StatsMetricRow(title: "Last 30 Days", metric: summary.lastThirtyDays, systemImage: "calendar.badge.clock")
                    StatsMetricRow(title: "All Time", metric: summary.allTimeDaily, systemImage: "checklist")
                }

                Section("Streaks") {
                    LabeledContent("Current streak") {
                        Text("\(summary.currentDailyStreak) day(s)")
                    }
                    LabeledContent("Best streak") {
                        Text("\(summary.bestDailyStreak) day(s)")
                    }
                    LabeledContent("Tracked days") {
                        Text("\(summary.trackedDayCount)")
                    }
                }

                Section("Collections") {
                    StatsMetricRow(title: "Collection Tasks", metric: summary.collections, systemImage: "tray.full")
                }
            } else {
                ProgressView("Loading stats")
            }
        }
        .navigationTitle("Stats")
        .onAppear(perform: load)
        .alert("Stats", isPresented: .constant(errorMessage != nil), actions: {
            Button("OK") {
                errorMessage = nil
            }
        }, message: {
            Text(errorMessage ?? "")
        })
    }

    private func load() {
        do {
            summary = try CompletionStatsService.summary(in: modelContext)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct StatsMetricRow: View {
    let title: String
    let metric: CompletionStatsMetric
    let systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.headline)

            ProgressView(
                value: Double(metric.completed),
                total: Double(max(metric.total, 1))
            ) {
                Text("\(metric.completed) of \(metric.total) complete")
                    .font(.subheadline)
            } currentValueLabel: {
                Text("\(metric.percentage)%")
                    .font(.caption)
            }
            .tint(.green)
        }
        .padding(.vertical, 4)
    }
}
