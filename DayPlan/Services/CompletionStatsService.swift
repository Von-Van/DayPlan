import Foundation
import SwiftData

struct CompletionStatsMetric: Equatable {
    let completed: Int
    let total: Int

    var percentage: Int {
        guard total > 0 else { return 0 }
        return Int((Double(completed) / Double(total) * 100).rounded())
    }
}

struct CompletionStatsSummary: Equatable {
    let today: CompletionStatsMetric
    let lastSevenDays: CompletionStatsMetric
    let lastThirtyDays: CompletionStatsMetric
    let allTimeDaily: CompletionStatsMetric
    let collections: CompletionStatsMetric
    let currentDailyStreak: Int
    let bestDailyStreak: Int
    let trackedDayCount: Int
}

enum CompletionStatsService {
    static func summary(in context: ModelContext, now: Date = .now) throws -> CompletionStatsSummary {
        let checklists = try context.fetch(FetchDescriptor<DailyChecklist>(
            sortBy: [SortDescriptor(\.date)]
        ))
        let collections = try context.fetch(FetchDescriptor<CollectionList>())
        let today = DateKeys.startOfDay(now)

        return CompletionStatsSummary(
            today: metric(for: checklists.filter { $0.date == today }),
            lastSevenDays: metric(for: checklists.filter {
                isDate($0.date, withinDays: 7, endingAt: today)
            }),
            lastThirtyDays: metric(for: checklists.filter {
                isDate($0.date, withinDays: 30, endingAt: today)
            }),
            allTimeDaily: metric(for: checklists),
            collections: CompletionStatsMetric(
                completed: collections.reduce(0) { $0 + $1.completedCount },
                total: collections.reduce(0) { $0 + $1.items.count }
            ),
            currentDailyStreak: currentStreak(from: checklists, endingAt: today),
            bestDailyStreak: bestStreak(from: checklists),
            trackedDayCount: checklists.filter { !$0.items.isEmpty }.count
        )
    }

    private static func metric(for checklists: [DailyChecklist]) -> CompletionStatsMetric {
        CompletionStatsMetric(
            completed: checklists.reduce(0) { $0 + $1.completedCount },
            total: checklists.reduce(0) { $0 + $1.items.count }
        )
    }

    private static func isDate(_ date: Date, withinDays dayCount: Int, endingAt endDate: Date) -> Bool {
        let start = Calendar.current.date(
            byAdding: .day,
            value: -(dayCount - 1),
            to: endDate
        ) ?? endDate
        return date >= start && date <= endDate
    }

    private static func currentStreak(from checklists: [DailyChecklist], endingAt today: Date) -> Int {
        let completedDays = Set(checklists.filter(isCompleteDay).map(\.date))
        var cursor = today
        var count = 0

        while completedDays.contains(cursor) {
            count += 1
            guard let previous = Calendar.current.date(byAdding: .day, value: -1, to: cursor) else {
                break
            }
            cursor = DateKeys.startOfDay(previous)
        }

        return count
    }

    private static func bestStreak(from checklists: [DailyChecklist]) -> Int {
        let completedDays = checklists
            .filter(isCompleteDay)
            .map(\.date)
            .sorted()
        guard !completedDays.isEmpty else { return 0 }

        var best = 1
        var current = 1
        for index in completedDays.indices.dropFirst() {
            let previous = completedDays[completedDays.index(before: index)]
            let expected = DateKeys.dayAfter(previous)
            if completedDays[index] == expected {
                current += 1
            } else {
                current = 1
            }
            best = max(best, current)
        }
        return best
    }

    private static func isCompleteDay(_ checklist: DailyChecklist) -> Bool {
        !checklist.items.isEmpty && checklist.completedCount == checklist.items.count
    }
}
