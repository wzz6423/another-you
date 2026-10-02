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
