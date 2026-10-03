import Foundation

struct ActivityRecord: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable { case prompt, suggestion }
    let id: String
    let occurredAt: String
    let kind: Kind
    var appName: String?

    var application: String {
        appName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    static func retained(_ records: [Self], now: Date = Date()) -> [Self] {
        let cutoff = now.addingTimeInterval(-186 * 86400)
        var seen = Set<String>()
        return records.filter {
            guard let date = AgentEvent.date(from: $0.occurredAt), date >= cutoff, date <= now else { return false }
            return seen.insert($0.id).inserted
        }
    }
}

enum ActivityPeriod: Int, CaseIterable, Identifiable {
    case month = 1, quarter = 3, halfYear = 6
    var id: Int { rawValue }
}

struct ActivityDay: Identifiable {
    let date: Date
    let count: Int
    var id: Date { date }
}

struct ActivityHour: Identifiable {
    let hour: Int
    let count: Int
    var id: Int { hour }
}

struct ActivitySummary {
    let days: [ActivityDay]
    let hours: [ActivityHour]
    let applications: [UsageBreakdown]
    let availableApplications: [String]
    let total: Int
    let todayTotal: Int
    let calendar: Calendar
    var activeDays: Int { days.filter { $0.count > 0 }.count }

    init(records: [ActivityRecord], period: ActivityPeriod, application: String? = nil,
         now: Date = Date(), calendar: Calendar = .current) {
        self.calendar = calendar
        let today = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: 1, to: today)!
        let start = calendar.date(byAdding: .month, value: -period.rawValue, to: end)!
        let valid = ActivityRecord.retained(records, now: now).compactMap { record -> (ActivityRecord, Date)? in
            guard let date = AgentEvent.date(from: record.occurredAt), date >= start else { return nil }
            return (record, date)
        }
        availableApplications = Array(Set(valid.map { $0.0.application })).sorted()
        let filtered = valid.filter { application == nil || $0.0.application == application }
        var daily: [Date: Int] = [:]
        var hourly: [Int: Int] = [:]
        var apps: [String: Int] = [:]
        for (record, date) in filtered {
            let day = calendar.startOfDay(for: date)
            daily[day, default: 0] += 1
            apps[record.application, default: 0] += 1
            if day == today { hourly[calendar.component(.hour, from: date), default: 0] += 1 }
        }
        var buckets: [ActivityDay] = []
        var day = start
        while day < end {
            buckets.append(ActivityDay(date: day, count: daily[day, default: 0]))
            day = calendar.date(byAdding: .day, value: 1, to: day)!
        }
        days = buckets
        hours = (0...calendar.component(.hour, from: now)).map { ActivityHour(hour: $0, count: hourly[$0, default: 0]) }
        applications = apps.map { UsageBreakdown(name: $0.key, count: $0.value) }
            .sorted { $0.count == $1.count ? $0.name < $1.name : $0.count > $1.count }
        total = filtered.count
        todayTotal = hourly.values.reduce(0, +)
    }

    var weeks: [[ActivityDay?]] {
        guard let first = days.first else { return [] }
        let offset = (calendar.component(.weekday, from: first.date) - calendar.firstWeekday + 7) % 7
        var cells = Array<ActivityDay?>(repeating: nil, count: offset) + days.map(Optional.some)
        cells += Array(repeating: nil, count: (7 - cells.count % 7) % 7)
        return stride(from: 0, to: cells.count, by: 7).map { Array(cells[$0..<$0 + 7]) }
    }
}
