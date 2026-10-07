import Foundation
import XCTest
@testable import AnotherYouCore

@MainActor
private final class VisibilityTestClient: AgentClient {
    var onMessage: (@MainActor @Sendable (AgentClientMessage) -> Void)?
    var commands: [[String: JSONValue]] = []

    func start(configURL: URL) throws { }
    func send(_ command: [String: JSONValue]) throws { commands.append(command) }
    func stop() async { onMessage?(.connection(.stopped)) }

    func emit(_ kind: String, _ payload: [String: JSONValue]) {
        onMessage?(.event(AgentEvent(id: UUID().uuidString, occurredAt: ISO8601DateFormatter().string(from: Date()),
                                    kind: kind, source: "agent", payload: payload)))
    }
}

@MainActor
final class ConversationVisibilityTests: XCTestCase {
    private let messages: [JSONValue] = [
        .object(["id": .string("failed-turn"), "prompt": .string("阅读一下屏幕"), "error": .string("fixture rejected")]),
        .object(["id": .string("successful-turn"), "prompt": .string("阅读一下屏幕"), "response": .string("屏幕内容")])
    ]

    private func session(_ id: String = "existing", state: String = "completed", messages: [JSONValue]? = nil) -> JSONValue {
        var payload: [String: JSONValue] = [
            "id": .string(id), "title": .string("阅读一下屏幕"), "appName": .string("Fixture"),
            "state": .string(state), "archived": .bool(false), "updatedAt": .string("2026-10-07T04:00:00Z")
        ]
        if let messages { payload["messages"] = .array(messages) }
        return .object(payload)
    }

    private func withStore(_ body: (AssistantStore, VisibilityTestClient) async throws -> Void) async throws {
        let domain = "another-you-visibility-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(domain)
        defer { defaults.removePersistentDomain(forName: domain); try? FileManager.default.removeItem(at: directory) }
        let client = VisibilityTestClient()
        let store = AssistantStore(client: client, repository: AgentSettingsRepository(dataDirectory: directory), defaults: defaults)
        client.onMessage?(.connection(.connected))
        client.emit("agent.status", ["model": .object(["configured": .bool(true)])])
        do { try await body(store, client) } catch { await store.shutdown(); throw error }
        await store.shutdown()
    }

    func testReturningToBoardKeepsCompletedHistoryAcrossSummaryRefreshAndReopen() async throws {
        try await withStore { store, client in
            client.emit("agent.status", ["conversations": .array([session()])])
            store.selectConversation("existing")
            let readID = try XCTUnwrap(client.commands.last?["readId"]?.string)
            client.emit("conversation.messages", ["readId": .string(readID), "conversationId": .string("existing"),
                                                   "conversation": session(messages: messages)])
            XCTAssertEqual(store.conversation.count, 2)

            store.newConversation()
            XCTAssertNil(store.selectedConversationID)
            XCTAssertTrue(store.conversation.isEmpty)
            client.emit("agent.status", ["conversations": .array([session()])])
            client.emit("agent.status", ["paused": .bool(false)])
            let entries = BoardEntry.filtered(store.sessions.map { BoardEntry(session: $0) }, query: "")
            XCTAssertEqual(entries.filter { !$0.archived && $0.completed }.map(\.id), ["existing"])
            XCTAssertEqual(store.sessions.first?.messages.count, 2)

            store.selectConversation("existing")
            XCTAssertEqual(store.conversation.map(\.id), ["failed-turn", "successful-turn"])
            XCTAssertEqual(store.conversation.last?.response, "屏幕内容")
        }
    }

    func testReturningBeforeReadFinishesIgnoresLateContentWithoutDroppingListEntry() async throws {
        try await withStore { store, client in
            client.emit("agent.status", ["conversations": .array([session()])])
            store.selectConversation("existing")
            let readID = try XCTUnwrap(client.commands.last?["readId"]?.string)
            XCTAssertTrue(store.isLoadingConversation)

            store.newConversation()
            client.emit("conversation.messages", ["readId": .string(readID), "conversationId": .string("existing"),
                                                   "conversation": session(messages: messages)])
            client.emit("conversation.updated", ["conversationId": .string("existing"), "conversations": .array([session()])])
            XCTAssertNil(store.selectedConversationID)
            XCTAssertFalse(store.isLoadingConversation)
            XCTAssertTrue(store.conversation.isEmpty)
            XCTAssertEqual(store.sessions.map(\.id), ["existing"])

            store.selectConversation("existing")
            let nextReadID = try XCTUnwrap(client.commands.last?["readId"]?.string)
            XCTAssertNotEqual(nextReadID, readID)
            client.emit("conversation.messages", ["readId": .string(nextReadID), "conversationId": .string("existing"),
                                                   "conversation": session(messages: messages)])
            XCTAssertEqual(store.conversation.count, 2)
        }
    }

    func testCompletedNewRequestRemainsInBoardAfterReturningAndReceivingSummaries() async throws {
        try await withStore { store, client in
            client.emit("agent.status", ["conversations": .array([session()])])
            XCTAssertTrue(store.ask("新话题"))
            let id = try XCTUnwrap(store.selectedConversationID)
            let requestID = try XCTUnwrap(client.commands.last?["requestId"]?.string)
            client.emit("conversation.updated", ["conversationId": .string(id),
                                                  "conversations": .array([session(), session(id, state: "running")])])
            client.emit("agent.response", ["requestId": .string(requestID), "conversationId": .string(id), "text": .string("已回复")])
            client.emit("conversation.updated", ["conversationId": .string(id), "conversations": .array([session(), session(id)])])
            XCTAssertFalse(store.hasPendingPrompt)

            store.newConversation()
            client.emit("agent.status", ["conversations": .array([session(), session(id)])])
            XCTAssertNil(store.selectedConversationID)
            let entries = store.sessions.map { BoardEntry(session: $0) }
            XCTAssertEqual(Set(entries.filter { !$0.archived && $0.completed }.map(\.id)), ["existing", id])
            store.selectConversation(id)
            XCTAssertEqual(store.conversation.first?.response, "已回复")
        }
    }
}
