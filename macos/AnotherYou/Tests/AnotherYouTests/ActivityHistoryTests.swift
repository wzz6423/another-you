import Combine
import XCTest
@testable import AnotherYouCore

@MainActor
private final class ActivityHistoryAgentClient: AgentClient {
    var onMessage: (@MainActor @Sendable (AgentClientMessage) -> Void)?
    func start(configURL: URL) throws {}
    func send(_ command: [String: JSONValue]) throws {}
    func stop() async {}
}

final class ActivityHistoryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func event(_ id: String, date: Date, category: ActivityCategory = .command) -> AgentEvent {
        AgentEvent(id: id, occurredAt: ISO8601DateFormatter().string(from: date), kind: "agent.activity", source: "agent",
                   payload: ["category": .string(category.rawValue), "phase": .string("completed")])
    }

    func testAllTimeRangesIncludeBothEdgesAndExcludeExpiredInvalidAndFutureEvents() {
        for period in UsagePeriod.allCases {
            let edge = event("edge", date: now.addingTimeInterval(-period.seconds))
            let current = event("current", date: now)
            let expired = event("expired", date: now.addingTimeInterval(-period.seconds - 1))
            let future = event("future", date: now.addingTimeInterval(1))
            let invalid = AgentEvent(id: "invalid", occurredAt: "invalid", kind: "agent.response", source: "agent", payload: [:])
            let snapshot = ActivityHistory(events: [edge, edge, current, expired, future, invalid], period: period, now: now)
            XCTAssertEqual(snapshot.events.map(\.id), ["current", "edge"])
            let later = ActivityHistory(events: [edge, current, future], period: period, now: now.addingTimeInterval(1))
            XCTAssertEqual(later.events.map(\.id), ["future", "current"])
        }
    }

    func testTimeCategoryAndGroupingUseTheSameFilteredEvents() {
        let events = [event("command-now", date: now), event("command-old", date: now.addingTimeInterval(-2 * 86400)),
                      event("thinking", date: now, category: .thinking), event("execution", date: now, category: .execution)]
        let daily = ActivityHistory(events: events, period: .day, category: .command, now: now)
        XCTAssertEqual(daily.events.map(\.id), ["command-now"])
        XCTAssertEqual(daily.groups.keys.sorted(by: { $0.rawValue < $1.rawValue }), [.command])
        XCTAssertEqual(daily.groups[.command], daily.events)
        let weekly = ActivityHistory(events: events, period: .week, now: now)
        XCTAssertEqual(weekly.groups[.command]?.count, 2)
        XCTAssertEqual(weekly.groups[.thinking]?.count, 1)
        XCTAssertEqual(weekly.groups[.execution]?.count, 1)
        XCTAssertEqual(weekly.groups.values.reduce(0) { $0 + $1.count }, weekly.events.count)
        XCTAssertTrue(ActivityHistory(events: events, period: .day, category: .error, now: now).events.isEmpty)
    }

    func testRetentionKeepsMoreThanTwoHundredEventsAndPreservesFutureEventsUntilVisible() {
        let recent = (0..<250).map { event("recent-\($0)", date: now.addingTimeInterval(-Double($0))) }
        let edge = event("edge", date: now.addingTimeInterval(-UsagePeriod.month.seconds))
        let future = event("future", date: now.addingTimeInterval(1))
        let expired = event("expired", date: now.addingTimeInterval(-UsagePeriod.month.seconds - 1))
        let retained = ActivityHistory.retained(recent + [edge, future, expired], now: now)
        XCTAssertEqual(retained.count, 252)
        XCTAssertEqual(ActivityHistory(events: retained, period: .month, now: now).events.count, 251)
        XCTAssertFalse(ActivityHistory.retained([edge], now: now.addingTimeInterval(1)).contains(edge))
    }

    @MainActor
    func testStoreMergesRestoredAndLiveHistoryWithoutARecordCountCap() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("another-you-activity-\(UUID().uuidString)")
        let suite = "another-you-activity-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let client = ActivityHistoryAgentClient()
        let store = AssistantStore(client: client, repository: AgentSettingsRepository(dataDirectory: directory), defaults: defaults,
                                   updater: UpdateController(driver: nil, defaults: defaults))
        let reference = Date()
        let restored = (0..<250).map { event("restored-\($0)", date: reference.addingTimeInterval(-Double($0))) }
        let payload = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(restored))
        let status = AgentEvent(id: "status", occurredAt: ISO8601DateFormatter().string(from: reference), kind: "agent.status",
                                source: "system", payload: ["history": payload])
        client.onMessage?(.event(status))
        XCTAssertEqual(store.history.count, 250)
        var publications = 0
        let subscription = store.$history.dropFirst().sink { _ in publications += 1 }
        client.onMessage?(.event(status))
        XCTAssertEqual(publications, 0)
        client.onMessage?(.event(event("live", date: reference)))
        client.onMessage?(.event(event("expired", date: reference.addingTimeInterval(-31 * 86400))))
        XCTAssertEqual(store.history.count, 251)
        XCTAssertEqual(publications, 1)
        subscription.cancel()
        await store.shutdown()
    }
}
