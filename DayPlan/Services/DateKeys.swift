import Foundation

enum DateKeys {
    static func startOfDay(_ date: Date, calendar: Calendar = .current) -> Date {
        calendar.startOfDay(for: date)
    }

    static func dayAfter(_ date: Date, calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: .day, value: 1, to: startOfDay(date, calendar: calendar))!
    }

    static func yesterday(from date: Date = .now, calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: .day, value: -1, to: startOfDay(date, calendar: calendar))!
    }

    static func dayKey(for date: Date, calendar: Calendar = .current) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        let year = components.year ?? 0
        let month = components.month ?? 0
        let day = components.day ?? 0
        return String(format: "%04d-%02d-%02d", year, month, day)
    }
}
