import Foundation

public enum UsagePeriod: String, CaseIterable, Identifiable, Sendable {
    case day = "24h", week = "7d", fortnight = "15d", month = "30d"
    public var id: String { rawValue }
    public var title: String { title(locale: AppLocalization.locale) }

    public func title(locale: Locale) -> String {
        switch self {
        case .day: AppLocalization.format("%d 小时", locale: locale, [24])
        case .week: AppLocalization.format("%d 天", locale: locale, [7])
        case .fortnight: AppLocalization.format("%d 天", locale: locale, [15])
        case .month: AppLocalization.format("%d 天", locale: locale, [30])
        }
    }
    public var seconds: TimeInterval {
        switch self { case .day: 86400; case .week: 7 * 86400; case .fortnight: 15 * 86400; case .month: 30 * 86400 }
    }
}

public struct UsageRecord: Codable, Identifiable, Equatable, Sendable {
    public struct Tokens: Codable, Equatable, Sendable {
        public let inputTokens: Int
        public let outputTokens: Int
        public let cacheReadTokens: Int
        public let cacheWriteTokens: Int
        public let totalTokens: Int
    }
    public struct ToolCall: Codable, Equatable, Sendable {
        public let name: String
        public let kind: String
    }
    public let id: String
    public let occurredAt: String
    public let source: String
    public let model: String
    public let outcome: String
    public let usage: Tokens?
    public let reasoningEffort: String
    public let toolCalls: [ToolCall]
    public var runId: String? = nil
    public var requestId: String? = nil
    public var suggestionId: String? = nil
    public var appName: String? = nil
    public var bundleId: String? = nil
    public var windowTitle: String? = nil
    public var route: String? = nil
    public var provider: String? = nil
    public var endpoint: String? = nil
    public var requestPath: String? = nil
    public var upstreamRequestId: String? = nil
    public var startedAt: String? = nil
    public var durationMs: Double? = nil

    static let retentionSeconds: TimeInterval = 186 * 86400

    var application: String {
        appName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    static func retained(_ records: [Self], now: Date = Date()) -> [Self] {
        let cutoff = now.addingTimeInterval(-retentionSeconds)
        var seen = Set<String>()
        return records.filter {
            guard !$0.id.isEmpty, let date = AgentEvent.date(from: $0.occurredAt), date >= cutoff else { return false }
            return seen.insert($0.id).inserted
        }
    }
}

enum UsageHeatmapScale {
    static let thresholds = [50_000_000, 100_000_000, 150_000_000, 200_000_000, 250_000_000]
    static let labels = ["0", "0–50M", "50–100M", "100–150M", "150–200M", "200–250M", "250M+"]

    static func level(for tokens: Int) -> Int {
        guard tokens > 0 else { return 0 }
        return (thresholds.firstIndex { tokens < $0 } ?? thresholds.count) + 1
    }
}

struct DailyUsage: Identifiable, Equatable {
    let date: Date
    var totalTokens = 0
    var knownCount = 0
    var unknownCount = 0
    var id: Date { date }

    func description(locale: Locale) -> String {
        if knownCount == 0 {
            return unknownCount == 0 ? AppLocalization.string("无用量记录", locale: locale)
                : AppLocalization.format("%d 次请求未报告用量", locale: locale, [unknownCount])
        }
        let tokens = "\(totalTokens.formatted(.number.locale(locale))) Token"
        return unknownCount == 0 ? tokens
            : "\(tokens) · \(AppLocalization.format("%d 次请求未报告用量", locale: locale, [unknownCount]))"
    }
}

struct DailyUsageSummary {
    let days: [DailyUsage]
    let weeks: [[DailyUsage?]]
    let availableApplications: [String]
    let calendar: Calendar
    var totalTokens: Int { days.reduce(0) { $0 + $1.totalTokens } }
    var knownCount: Int { days.reduce(0) { $0 + $1.knownCount } }
    var unknownCount: Int { days.reduce(0) { $0 + $1.unknownCount } }
    var usageDays: Int { days.filter { $0.knownCount + $0.unknownCount > 0 }.count }

    init(records: [UsageRecord], period: ActivityPeriod, application: String? = nil,
         now: Date = Date(), calendar: Calendar = .current) {
        self.calendar = calendar
        let layout = ActivitySummary(records: [], period: period, now: now, calendar: calendar)
        let start = layout.days.first?.date ?? now
        let valid = UsageRecord.retained(records, now: now).compactMap { record -> (UsageRecord, Date)? in
            guard let date = AgentEvent.date(from: record.occurredAt), date >= start, date <= now else { return nil }
            return (record, date)
        }
        availableApplications = Array(Set(valid.map { $0.0.application })).sorted()
        var daily = Dictionary(uniqueKeysWithValues: layout.days.map { ($0.date, DailyUsage(date: $0.date)) })
        for (record, date) in valid where application == nil || record.application == application {
            let day = calendar.startOfDay(for: date)
            guard var value = daily[day] else { continue }
            if let usage = record.usage {
                value.totalTokens += usage.totalTokens
                value.knownCount += 1
            } else {
                value.unknownCount += 1
            }
            daily[day] = value
        }
        days = layout.days.compactMap { daily[$0.date] }
        weeks = layout.weeks.map { week in week.map { day in day.flatMap { daily[$0.date] } } }
    }
}

public struct UsageBreakdown: Identifiable, Sendable {
    public let name: String
    public let count: Int
    public var id: String { name }
}

public struct UsageSummary: Sendable {
    public let records: [UsageRecord]
    public let knownCount: Int
    public var unknownCount: Int { records.count - knownCount }
    public let totalTokens: Int
    public let inputTokens: Int
    public let outputTokens: Int
    public let cacheTokens: Int
    public let failedCount: Int
    public let models: [UsageBreakdown]
    public let reasoning: [UsageBreakdown]
    public let tools: [UsageBreakdown]

    public init(records: [UsageRecord], period: UsagePeriod, now: Date = Date()) {
        var seen = Set<String>()
        let cutoff = now.addingTimeInterval(-period.seconds)
        var filtered: [UsageRecord] = []
        var known = 0, total = 0, input = 0, output = 0, cache = 0, failed = 0
        var values: [String: Int] = [:]
        var efforts: [String: Int] = [:]
        var calls: [String: Int] = [:]
        for record in records {
            guard let date = AgentEvent.date(from: record.occurredAt), date >= cutoff, date <= now,
                  seen.insert(record.id).inserted else { continue }
            filtered.append(record)
            if let usage = record.usage {
                known += 1
                total += usage.totalTokens
                input += usage.inputTokens
                output += usage.outputTokens
                cache += usage.cacheReadTokens + usage.cacheWriteTokens
                values[record.model, default: 0] += usage.totalTokens
            }
            if record.outcome == "failed" { failed += 1 }
            efforts[record.reasoningEffort == "unknown" ? "未报告" : record.reasoningEffort, default: 0] += 1
            for tool in record.toolCalls { calls["\(tool.kind) · \(tool.name)", default: 0] += 1 }
        }
        self.records = filtered
        knownCount = known
        totalTokens = total
        inputTokens = input
        outputTokens = output
        cacheTokens = cache
        failedCount = failed
        models = Self.sorted(values)
        reasoning = Self.sorted(efforts)
        tools = Self.sorted(calls)
    }

    private static func sorted(_ values: [String: Int]) -> [UsageBreakdown] {
        values.map { UsageBreakdown(name: $0.key, count: $0.value) }
            .sorted { $0.count == $1.count ? $0.name < $1.name : $0.count > $1.count }
    }
}
