import Foundation
import Testing
@testable import AnotherYouCore

struct ActivityTests {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        value.firstWeekday = 2
        return value
    }

    private func date(_ value: String) -> Date { AgentEvent.date(from: value)! }
    private func record(_ id: String, _ timestamp: String, app: String? = nil) -> ActivityRecord {
        ActivityRecord(id: id, occurredAt: timestamp, kind: .prompt, appName: app)
    }

    @Test func calendarMonthsIncludeZeroDaysAndExcludeOutsideRecords() {
        let now = date("2026-10-03T12:00:00Z")
        let records = [record("before", "2026-09-03T23:59:59Z"), record("start", "2026-09-04T00:00:00Z"),
                       record("today", "2026-10-03T12:00:00Z"), record("future", "2026-10-03T12:00:01Z")]
        let summary = ActivitySummary(records: records, period: .month, now: now, calendar: calendar)
        #expect(summary.days.count == 30)
        #expect(summary.days.first?.date == date("2026-09-04T00:00:00Z"))
        #expect(summary.total == 2)
        #expect(summary.activeDays == 2)
        #expect(summary.days.filter { $0.count == 0 }.count == 28)
        #expect(ActivitySummary(records: [], period: .quarter, now: now, calendar: calendar).days.count == 92)
        #expect(ActivitySummary(records: [], period: .halfYear, now: now, calendar: calendar).days.count == 183)
    }

    @Test func appFilteringAndRankingsUseTheSameDeduplicatedEvents() {
        let timestamp = "2026-10-03T12:00:00Z"
        let safari = record("a", timestamp, app: " Safari ")
        let records = [safari, safari, record("b", timestamp, app: "Safari"),
                       record("c", timestamp, app: "Xcode"), record("d", timestamp, app: "  "), record("bad", "invalid")]
        let all = ActivitySummary(records: records, period: .month, now: date(timestamp), calendar: calendar)
        #expect(all.total == 4)
        #expect(all.applications.first?.name == "Safari")
        #expect(all.applications.first?.count == 2)
        #expect(all.availableApplications == ["", "Safari", "Xcode"])
        let filtered = ActivitySummary(records: records, period: .month, application: "Safari", now: date(timestamp), calendar: calendar)
        #expect(filtered.total == 2)
        #expect(filtered.todayTotal == 2)
        #expect(filtered.applications.count == 1)
        #expect(filtered.hours.reduce(0) { $0 + $1.count } == filtered.days.reduce(0) { $0 + $1.count })
        #expect(ActivitySummary(records: records, period: .month, application: "", now: date(timestamp), calendar: calendar).total == 1)
    }

    @Test func todayUsesLocalMidnightAndDoesNotDrawFutureHours() {
        var local = calendar
        local.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let now = date("2026-10-02T16:30:00Z")
        let summary = ActivitySummary(records: [record("yesterday", "2026-10-02T15:59:59Z"),
            record("today", "2026-10-02T16:00:00Z")], period: .month, now: now, calendar: local)
        #expect(summary.todayTotal == 1)
        #expect(summary.hours.count == 1)
        #expect(summary.hours.first?.hour == 0)
        #expect(summary.hours.first?.count == 1)
        #expect(summary.days.last?.count == 1)
    }

    @Test func daylightSavingKeepsLocalDaysAndMergesRepeatedHours() {
        var local = calendar
        local.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let spring = ActivitySummary(records: [record("one", "2026-03-08T09:30:00Z"), record("three", "2026-03-08T10:30:00Z")],
                                     period: .month, now: date("2026-03-08T20:00:00Z"), calendar: local)
        #expect(spring.todayTotal == 2)
        #expect(spring.hours[1].count == 1)
        #expect(spring.hours[2].count == 0)
        #expect(spring.hours[3].count == 1)
        #expect(Set(spring.days.map(\.date)).count == spring.days.count)
        let fall = ActivitySummary(records: [record("first", "2026-11-01T08:30:00Z"), record("second", "2026-11-01T09:30:00Z")],
                                   period: .month, now: date("2026-11-01T20:00:00Z"), calendar: local)
        #expect(fall.hours[1].count == 2)
        #expect(fall.days.last?.count == 2)
    }

    @Test func heatmapAlignsWeekdaysAndDoesNotInventOutsideDays() {
        let summary = ActivitySummary(records: [], period: .month, now: date("2026-10-03T12:00:00Z"), calendar: calendar)
        #expect(summary.weeks.allSatisfy { $0.count == 7 })
        #expect(summary.weeks.first?.prefix(4).allSatisfy { $0 == nil } == true)
        #expect(summary.weeks.flatMap { $0 }.compactMap { $0 }.map(\.date) == summary.days.map(\.date))
        #expect(summary.hours.allSatisfy { $0.count == 0 })
        #expect(summary.total == 0)
    }

    @Test func retentionKeepsExactBoundaryAndLegacyMissingApp() throws {
        let now = date("2026-10-03T12:00:00Z")
        let cutoff = now.addingTimeInterval(-186 * 86400)
        let records = [record("at", ISO8601DateFormatter().string(from: cutoff)),
                       record("old", ISO8601DateFormatter().string(from: cutoff.addingTimeInterval(-1)))]
        #expect(ActivityRecord.retained(records, now: now).map(\.id) == ["at"])
        let legacy = try JSONDecoder().decode(ActivityRecord.self, from: Data(#"{"id":"legacy","occurredAt":"2026-10-03T12:00:00Z","kind":"suggestion"}"#.utf8))
        #expect(legacy.application.isEmpty)
    }

    @MainActor @Test func storeRestoresAndDeduplicatesLiveActivityEvents() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("another-you-activity-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "another-you-activity-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { try? FileManager.default.removeItem(at: directory); defaults.removePersistentDomain(forName: suite) }
        let client = ActivityTestClient()
        let store = AssistantStore(client: client, repository: AgentSettingsRepository(dataDirectory: directory), defaults: defaults)
        let now = ISO8601DateFormatter().string(from: Date())
        let value: JSONValue = .object(["id": .string("saved"), "occurredAt": .string(now), "kind": .string("prompt"), "appName": .string("Safari")])
        client.onMessage?(.event(AgentEvent(id: "status", occurredAt: now, kind: "agent.status", source: "agent",
            payload: ["paused": .bool(true), "activityRecords": .array([value, value])])))
        let live = AgentEvent(id: "live", occurredAt: now, kind: "activity.recorded", source: "agent",
                              payload: ["kind": .string("suggestion"), "appName": .string("Xcode")])
        client.onMessage?(.event(live))
        client.onMessage?(.event(live))
        #expect(store.activityRecords.map(\.id) == ["saved", "live"])
        #expect(store.activityRecords.last?.appName == "Xcode")
        await store.shutdown()
    }
}

@MainActor private final class ActivityTestClient: AgentClient {
    var onMessage: (@MainActor @Sendable (AgentClientMessage) -> Void)?
    func start(configURL: URL) throws {}
    func send(_ command: [String: JSONValue]) throws {}
    func stop() async {}
}
