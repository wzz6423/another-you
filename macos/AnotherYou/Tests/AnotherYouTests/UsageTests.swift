import Foundation
import Testing
@testable import AnotherYouCore

struct UsageTests {
    private func record(_ id: String, daysAgo: Double = 0, model: String = "model-a", tokens: Int? = 100, effort: String = "high",
                        timestamp: String? = nil, app: String? = nil) -> UsageRecord {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        return UsageRecord(id: id, occurredAt: timestamp ?? ISO8601DateFormatter().string(from: now.addingTimeInterval(-daysAgo * 86400)), source: "prompt", model: model, outcome: "completed", usage: tokens.map { UsageRecord.Tokens(inputTokens: $0, outputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0, totalTokens: $0) }, reasoningEffort: effort, toolCalls: [.init(name: "search", kind: "mcp")], appName: app)
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

    @Test func fixedHeatmapThresholdsIncludeEachLowerBoundaryAndCapAt250Million() {
        let examples = [(0, 0), (1, 1), (49_999_999, 1), (50_000_000, 2), (99_999_999, 2),
                        (100_000_000, 3), (149_999_999, 3), (150_000_000, 4), (199_999_999, 4),
                        (200_000_000, 5), (249_999_999, 5), (250_000_000, 6), (Int.max, 6)]
        for (tokens, expected) in examples { #expect(UsageHeatmapScale.level(for: tokens) == expected) }
    }

    @Test func heatmapUsesReportedTokensAndAppAttributionWithoutCountingRequestsOrDuplicates() {
        let now = AgentEvent.date(from: "2026-10-03T12:00:00Z")!
        let recent = record("recent", tokens: 50_000_000, timestamp: "2026-10-03T10:00:00Z", app: " Safari ")
        let older = record("older", tokens: 200_000_000, timestamp: "2026-08-01T12:00:00Z", app: "Safari")
        let other = record("other", tokens: 5_000_000_000, timestamp: "2026-10-02T12:00:00Z", app: "Xcode")
        let unassociated = record("unassociated", tokens: 10, timestamp: "2026-10-03T11:00:00Z")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let all = DailyUsageSummary(records: [recent, recent, older, other, unassociated], period: .halfYear, now: now, calendar: calendar)
        let safari = DailyUsageSummary(records: [recent, recent, older, other, unassociated], period: .halfYear,
                                       application: "Safari", now: now, calendar: calendar)
        #expect(all.totalTokens == 5_250_000_010)
        #expect(all.knownCount == 4)
        #expect(all.availableApplications == ["", "Safari", "Xcode"])
        #expect(safari.totalTokens == 250_000_000)
        #expect(safari.knownCount == 2)
        #expect(safari.usageDays == 2)
        #expect(UsageHeatmapScale.level(for: safari.days.last!.totalTokens) == 2)
        #expect(UsageHeatmapScale.level(for: all.days.last!.totalTokens) == 2)
        #expect(all.days.count == ActivitySummary(records: [], period: .halfYear, now: now, calendar: calendar).days.count)
        #expect(all.weeks.allSatisfy { $0.count == 7 })
        #expect(all.weeks.flatMap { $0 }.compactMap { $0 }.map(\.date) == all.days.map(\.date))
        #expect(DailyUsageSummary(records: [unassociated], period: .halfYear, application: "", now: now, calendar: calendar).totalTokens == 10)
    }

    @Test func dailyUsageDistinguishesMissingReportedZeroAndPartiallyUnknownUsage() {
        let now = AgentEvent.date(from: "2026-10-03T12:00:00Z")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let summary = DailyUsageSummary(records: [
            record("zero", tokens: 0, timestamp: "2026-10-01T10:00:00Z"),
            record("unknown", tokens: nil, timestamp: "2026-10-02T10:00:00Z"),
            record("known", tokens: 20, timestamp: "2026-10-03T10:00:00Z"),
            record("partial", tokens: nil, timestamp: "2026-10-03T10:01:00Z"),
        ], period: .month, now: now, calendar: calendar)
        let days = Array(summary.days.suffix(4))
        #expect(summary.knownCount == 2)
        #expect(summary.unknownCount == 2)
        #expect(summary.totalTokens == 20)
        #expect(days[0].knownCount == 0 && days[0].unknownCount == 0)
        #expect(days[1].knownCount == 1 && days[1].totalTokens == 0)
        #expect(days[2].knownCount == 0 && days[2].unknownCount == 1)
        #expect(days[3].knownCount == 1 && days[3].unknownCount == 1)
        let locale = Locale(identifier: "en")
        #expect(days[1].description(locale: locale) == "0 Token")
        #expect(!days[0].description(locale: locale).contains("0 Token"))
        #expect(!days[2].description(locale: locale).contains("0 Token"))
        #expect(days[3].description(locale: locale).hasPrefix("20 Token · "))
    }

    @Test func dailyUsageUsesLocalMidnightAndExcludesFutureInvalidAndOutsideDates() {
        let now = AgentEvent.date(from: "2026-10-02T16:30:00Z")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let summary = DailyUsageSummary(records: [
            record("yesterday", tokens: 10, timestamp: "2026-10-02T15:59:59Z"),
            record("today", tokens: 20, timestamp: "2026-10-02T16:00:00Z"),
            record("future", tokens: 1_000, timestamp: "2026-10-02T16:30:01Z"),
            record("old", tokens: 1_000, timestamp: "2026-08-01T00:00:00Z"),
            record("invalid", tokens: 1_000, timestamp: "invalid"),
        ], period: .month, now: now, calendar: calendar)
        #expect(summary.totalTokens == 30)
        #expect(summary.knownCount == 2)
        #expect(summary.days.last?.date == AgentEvent.date(from: "2026-10-02T16:00:00Z"))
        #expect(summary.days.last?.totalTokens == 20)
        #expect(summary.days.dropLast().last?.totalTokens == 10)
    }

    @Test func dailyUsageMergesRepeatedDaylightSavingHours() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let summary = DailyUsageSummary(records: [
            record("first", tokens: 50_000_000, timestamp: "2026-11-01T08:30:00Z"),
            record("second", tokens: 50_000_000, timestamp: "2026-11-01T09:30:00Z"),
        ], period: .month, now: AgentEvent.date(from: "2026-11-01T20:00:00Z")!, calendar: calendar)
        #expect(summary.days.last?.totalTokens == 100_000_000)
        #expect(summary.usageDays == 1)
        #expect(Set(summary.days.map(\.date)).count == summary.days.count)
    }

    @Test func usageRetentionKeeps186DayBoundaryAndDeduplicatesValidRecords() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let edge = record("edge", daysAgo: 186)
        let expired = record("expired", timestamp: ISO8601DateFormatter().string(from: now.addingTimeInterval(-186 * 86400 - 1)))
        let future = record("future", daysAgo: -1)
        let retained = UsageRecord.retained([edge, edge, expired, future, record("invalid", timestamp: "invalid"), record("")], now: now)
        #expect(retained.map(\.id) == ["edge", "future"])
        #expect(UsageRecord.retained([edge], now: now.addingTimeInterval(1)).isEmpty)
    }

    @MainActor @Test func storeRetainsHistoricalUsageWhenLiveUsageArrives() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("another-you-usage-\(UUID())")
        let suite = "another-you-usage-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { try? FileManager.default.removeItem(at: directory); defaults.removePersistentDomain(forName: suite) }
        let client = UsageTestClient()
        let store = AssistantStore(client: client, repository: AgentSettingsRepository(dataDirectory: directory), defaults: defaults,
                                   updater: UpdateController(driver: nil, defaults: defaults))
        let now = Date()
        let timestamp = ISO8601DateFormatter().string(from: now)
        let old = record("old", timestamp: ISO8601DateFormatter().string(from: now.addingTimeInterval(-60 * 86400)), app: "Safari")
        let expired = record("expired", timestamp: ISO8601DateFormatter().string(from: now.addingTimeInterval(-187 * 86400)))
        let restored = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode([old, expired]))
        client.onMessage?(.event(AgentEvent(id: "status", occurredAt: timestamp, kind: "agent.status", source: "agent", payload: ["usageRecords": restored])))
        let live = record("live", timestamp: timestamp, app: "Safari")
        let payload = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(live)).object!
        let event = AgentEvent(id: live.id, occurredAt: timestamp, kind: "agent.usage", source: "agent", payload: payload)
        client.onMessage?(.event(event))
        client.onMessage?(.event(event))
        #expect(store.usageRecords.map(\.id) == ["old", "live"])
        #expect(store.usageRecords.allSatisfy { $0.application == "Safari" })
        await store.shutdown()
    }
}

@MainActor private final class UsageTestClient: AgentClient {
    var onMessage: (@MainActor @Sendable (AgentClientMessage) -> Void)?
    func start(configURL: URL) throws {}
    func send(_ command: [String: JSONValue]) throws {}
    func stop() async {}
}
