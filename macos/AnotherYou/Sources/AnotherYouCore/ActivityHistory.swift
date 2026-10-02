import Foundation

struct ActivityHistory {
    let events: [AgentEvent]
    let groups: [ActivityCategory: [AgentEvent]]

    init(events: [AgentEvent], period: UsagePeriod, category: ActivityCategory = .all, now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-period.seconds)
        var seen = Set<String>()
        let matches = Self.dated(events).filter { event, date in
            date >= cutoff && date <= now && event.activityCategory != nil
                && (category == .all || event.activityCategory == category) && seen.insert(event.id).inserted
        }.sorted { $0.1 > $1.1 }.map(\.0)
        self.events = matches
        groups = Dictionary(grouping: matches, by: { $0.activityCategory! })
    }

    static func retained(_ events: [AgentEvent], now: Date) -> [AgentEvent] {
        let cutoff = now.addingTimeInterval(-UsagePeriod.month.seconds)
        return dated(events).filter { $0.1 >= cutoff }.map(\.0)
    }

    private static func dated(_ events: [AgentEvent]) -> [(AgentEvent, Date)] {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let standard = ISO8601DateFormatter()
        return events.compactMap { event in
            guard let date = fractional.date(from: event.occurredAt) ?? standard.date(from: event.occurredAt) else { return nil }
            return (event, date)
        }
    }
}
