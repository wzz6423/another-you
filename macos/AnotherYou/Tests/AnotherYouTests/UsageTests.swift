import Foundation
import Testing
@testable import AnotherYouCore

struct UsageTests {
    private func record(_ id: String, daysAgo: Double = 0, model: String = "model-a", tokens: Int? = 100, effort: String = "high") -> UsageRecord {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        return UsageRecord(id: id, occurredAt: ISO8601DateFormatter().string(from: now.addingTimeInterval(-daysAgo * 86400)), source: "prompt", model: model, outcome: "completed", usage: tokens.map { UsageRecord.Tokens(inputTokens: $0, outputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0, totalTokens: $0) }, reasoningEffort: effort, toolCalls: [.init(name: "search", kind: "mcp")])
    }

    @Test func periodBoundariesAndUnknownUsage() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let records = [record("a"), record("b", daysAgo: 1, tokens: 0), record("c", daysAgo: 2, tokens: nil), record("d", daysAgo: 8), record("e", daysAgo: 16), record("f", daysAgo: 31)]
        #expect(UsageSummary(records: records, period: .day, now: now).records.count == 2)
        #expect(UsageSummary(records: records, period: .week, now: now).records.count == 3)
        #expect(UsageSummary(records: records, period: .fortnight, now: now).records.count == 4)
        let summary = UsageSummary(records: records, period: .month, now: now)
        #expect(summary.records.count == 5)
        #expect(summary.totalTokens == 300)
        #expect(summary.unknownCount == 1)
        #expect(summary.knownCount == 4)
    }

    @Test func rankingsDeduplicateAndKeepToolKinds() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let first = record("a", model: "small", tokens: 10, effort: "off")
        let summary = UsageSummary(records: [first, first, record("b", model: "large", tokens: 300), record("c", tokens: nil, effort: "unknown")], period: .day, now: now)
        #expect(summary.models.first?.name == "large")
        #expect(summary.totalTokens == 310)
        #expect(summary.reasoning.contains { $0.name == "未报告" })
        #expect(summary.tools.first?.name == "mcp · search")
        #expect(summary.tools.first?.count == 3)
    }
}
