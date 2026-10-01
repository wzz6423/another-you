import XCTest
@testable import AnotherYouCore

final class MockAgentClientTests: XCTestCase {
    func testMockClientReturnsTodaySuggestions() {
        let cards = MockAgentClient(now: Date(timeIntervalSince1970: 1_000)).loadToday()

        XCTAssertEqual(cards.count, 4)
        XCTAssertEqual(cards.filter { $0.state == .pending }.count, 4)
        XCTAssertEqual(cards.first?.kind, .focus)
    }
}

@MainActor
final class AssistantStoreTests: XCTestCase {
    func testActionsMoveCardThroughStates() {
        let store = AssistantStore(client: MockAgentClient(now: Date(timeIntervalSince1970: 1_000)))
        let card = store.cards[0]

        store.apply(.later, to: card)
        XCTAssertEqual(store.cards[0].state, .scheduled)

        store.apply(.execute, to: card)
        XCTAssertEqual(store.cards[0].state, .done)
        XCTAssertEqual(store.completedCount, 1)
        XCTAssertTrue(store.statusMessage.hasPrefix("已执行"))
    }

    func testRefreshLoadsFreshSuggestions() {
        let store = AssistantStore(client: MockAgentClient(now: Date(timeIntervalSince1970: 1_000)))
        store.apply(.ignore, to: store.cards[0])

        store.refresh()

        XCTAssertEqual(store.cards.count, 4)
        XCTAssertEqual(store.pendingCount, 4)
        XCTAssertEqual(store.statusMessage, "已更新今日建议")
    }
}
