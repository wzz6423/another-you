import Foundation
import XCTest
@testable import AnotherYouCore

@MainActor
private final class QuickChatTestClient: AgentClient {
    var onMessage: (@MainActor @Sendable (AgentClientMessage) -> Void)?
    var commands: [[String: JSONValue]] = []
    var failSend = false

    func start(configURL: URL) throws { }
    func send(_ command: [String: JSONValue]) throws {
        if failSend { throw CocoaError(.fileWriteUnknown) }
        commands.append(command)
    }
    func stop() async { onMessage?(.connection(.stopped)) }
    func emit(_ kind: String, _ payload: [String: JSONValue]) {
        onMessage?(.event(AgentEvent(id: UUID().uuidString, occurredAt: ISO8601DateFormatter().string(from: Date()),
                                    kind: kind, source: "agent", payload: payload)))
    }
}

@MainActor
final class QuickChatSessionTests: XCTestCase {
    private func session(_ id: String = "history", archived: Bool = false,
                         messages: [ConversationMessage]? = nil) -> JSONValue {
        let messages = messages ?? [ConversationMessage(id: "\(id)-turn", prompt: "历史输入", response: "历史回复")]
        return .object([
            "id": .string(id), "title": .string(id), "state": .string("completed"), "archived": .bool(archived),
            "updatedAt": .string("2026-10-07T04:00:00Z"),
            "messages": .array(messages.map { message in
                var value: [String: JSONValue] = ["id": .string(message.id), "prompt": .string(message.prompt)]
                if let response = message.response { value["response"] = .string(response) }
                if let error = message.error { value["error"] = .string(error) }
                return .object(value)
            })
        ])
    }

    private func attachment(_ value: UInt8 = 1) -> ScreenAttachment {
        ScreenAttachment(capture: DesktopCapture(imageData: Data([value]), mimeType: "image/png",
                                                 context: ["appName": .string("Fixture")], mode: .window))
    }

    private func withStore(desktop: DesktopSession? = nil,
                           _ body: (AssistantStore, QuickChatTestClient) async throws -> Void) async throws {
        let domain = "another-you-quick-chat-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defaults.set(false, forKey: "notificationsEnabled")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(domain)
        defer {
            defaults.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: directory)
        }
        let client = QuickChatTestClient()
        let store = AssistantStore(client: client, repository: AgentSettingsRepository(dataDirectory: directory), defaults: defaults,
                                   updater: UpdateController(driver: nil, defaults: defaults), desktop: desktop ?? DesktopSession())
        client.onMessage?(.connection(.connected))
        client.emit("agent.status", ["model": .object(["configured": .bool(true)])])
        do { try await body(store, client) } catch { await store.shutdown(); throw error }
        await store.shutdown()
    }

    private func select(_ value: JSONValue, store: AssistantStore, client: QuickChatTestClient) throws {
        let id = try XCTUnwrap(value.object?["id"]?.string)
        store.selectConversation(id)
        let readID = try XCTUnwrap(client.commands.last?["readId"]?.string)
        client.emit("conversation.messages", ["readId": .string(readID), "conversationId": .string(id), "conversation": value])
    }

    private func completePrompt(store: AssistantStore, client: QuickChatTestClient) throws -> JSONValue {
        let id = try XCTUnwrap(store.selectedConversationID)
        let requestID = try XCTUnwrap(store.conversation.last?.id)
        client.emit("agent.response", ["requestId": .string(requestID), "text": .string("已完成")])
        return session(id, messages: store.conversation)
    }

    func testEachQuickSubmissionCreatesANewSessionAndHistoryCanStillContinue() async throws {
        try await withStore { store, client in
            let history = session()
            client.emit("agent.status", ["conversations": .array([history])])
            try select(history, store: store, client: client)

            XCTAssertTrue(store.ask("第一次快速输入", startsNewConversation: true))
            let firstID = try XCTUnwrap(client.commands.last?["conversationId"]?.string)
            XCTAssertNotEqual(firstID, "history")
            XCTAssertEqual(store.conversation.map(\.prompt), ["第一次快速输入"])
            XCTAssertEqual(Set(store.sessions.map(\.id)), ["history", firstID])
            let first = try completePrompt(store: store, client: client)
            client.emit("conversation.updated", ["conversations": .array([history, first])])

            XCTAssertTrue(store.ask("第二次快速输入", startsNewConversation: true))
            let secondID = try XCTUnwrap(client.commands.last?["conversationId"]?.string)
            XCTAssertNotEqual(secondID, firstID)
            XCTAssertNotEqual(secondID, "history")
            XCTAssertEqual(store.conversation.map(\.prompt), ["第二次快速输入"])
            let second = try completePrompt(store: store, client: client)
            client.emit("conversation.updated", ["conversations": .array([history, first, second])])
            XCTAssertEqual(Set(store.sessions.map(\.id)), Set(["history", firstID, secondID]))

            try select(history, store: store, client: client)
            XCTAssertEqual(store.conversation.first?.response, "历史回复")
            XCTAssertTrue(store.ask("从主窗口继续"))
            XCTAssertEqual(client.commands.last?["conversationId"], .string("history"))
            XCTAssertEqual(store.conversation.map(\.prompt), ["历史输入", "从主窗口继续"])
        }
    }

    func testQuickSubmissionPreservesMainDraftsWithoutReusingConsumedAttachments() async throws {
        try await withStore { store, client in
            let history = session()
            client.emit("agent.status", ["conversations": .array([history])])
            let boardAttachment = attachment(1)
            store.setInputDraft("看板未发草稿", for: .conversation)
            store.desktop.replaceAttachments([boardAttachment])
            try select(history, store: store, client: client)
            store.setInputDraft("历史会话未发草稿", for: .conversation)
            let quickAttachment = attachment(2)
            store.desktop.replaceAttachments([quickAttachment])
            store.desktop.allowForeground = true

            XCTAssertTrue(store.ask("单独讨论截图", startsNewConversation: true))
            XCTAssertEqual(client.commands.last?["attachments"], .array([quickAttachment.payload]))
            XCTAssertEqual(client.commands.last?["allowForeground"], .bool(true))
            XCTAssertEqual(store.conversation.first?.attachments, [quickAttachment])
            XCTAssertEqual(store.inputDraft(for: .conversation), "")
            XCTAssertTrue(store.desktop.attachments.isEmpty)
            let quick = try completePrompt(store: store, client: client)
            client.emit("conversation.updated", ["conversations": .array([history, quick])])

            try select(history, store: store, client: client)
            XCTAssertEqual(store.inputDraft(for: .conversation), "历史会话未发草稿")
            XCTAssertTrue(store.desktop.attachments.isEmpty)
            store.newConversation()
            XCTAssertEqual(store.inputDraft(for: .conversation), "看板未发草稿")
            XCTAssertEqual(store.desktop.attachments, [boardAttachment])
        }
    }

    func testQuickSubmissionFromTheBoardPreservesItsUnsentText() async throws {
        try await withStore { store, client in
            let commandCount = client.commands.count
            store.setInputDraft("看板未发草稿", for: .conversation)
            store.setInputDraft("临时输入草稿", for: .quickChat)
            XCTAssertNil(store.selectedConversationID)
            XCTAssertTrue(store.sessions.isEmpty)
            XCTAssertTrue(store.conversation.isEmpty)
            XCTAssertEqual(client.commands.count, commandCount)

            XCTAssertTrue(store.ask(store.inputDraft(for: .quickChat), startsNewConversation: true))
            XCTAssertEqual(store.conversation.map(\.prompt), ["临时输入草稿"])
            XCTAssertEqual(store.inputDraft(for: .conversation), "")
            _ = try completePrompt(store: store, client: client)
            store.newConversation()
            XCTAssertEqual(store.inputDraft(for: .conversation), "看板未发草稿")
        }
    }

    func testQuickSubmissionRunsAlongsideHistoryAndRoutesLateRepliesToTheirOwnSessions() async throws {
        try await withStore { store, client in
            let history = session()
            let other = session("other")
            client.emit("agent.status", ["conversations": .array([history, other])])
            try select(history, store: store, client: client)
            XCTAssertTrue(store.ask("旧会话任务"))
            let oldRequestID = try XCTUnwrap(store.conversation.last?.id)
            store.setInputDraft("并行的快速输入", for: .quickChat)
            XCTAssertTrue(store.ask(store.inputDraft(for: .quickChat), startsNewConversation: true))
            let quickID = try XCTUnwrap(client.commands.last?["conversationId"]?.string)
            XCTAssertFalse(["history", "other"].contains(quickID))
            XCTAssertEqual(store.conversation.map(\.prompt), ["并行的快速输入"])
            XCTAssertTrue(store.hasPendingPrompt)
            XCTAssertFalse(client.commands.contains { $0["op"] == .string("cancel") })
            let quick = try completePrompt(store: store, client: client)
            XCTAssertFalse(store.selectedConversationHasPendingPrompt)
            XCTAssertTrue(store.hasPendingPrompt)
            client.emit("agent.response", ["requestId": .string(oldRequestID), "conversationId": .string("history"), "text": .string("旧会话独立完成")])
            XCTAssertFalse(store.hasPendingPrompt)
            XCTAssertEqual(store.conversation.first?.response, "已完成")
            XCTAssertEqual(store.sessions.first { $0.id == "history" }?.messages.last?.response, "旧会话独立完成")
            client.emit("conversation.updated", ["conversations": .array([session(messages: store.sessions.first { $0.id == "history" }?.messages), other, quick])])
            store.newConversation()
            XCTAssertEqual(store.sessions.count, 3)
            store.selectConversation("history")
            XCTAssertEqual(store.conversation.last?.response, "旧会话独立完成")
        }
    }

    func testQuickSubmissionDoesNotWaitForHistoryAndIgnoresItsLateRead() async throws {
        try await withStore { store, client in
            let history = session()
            client.emit("agent.status", ["conversations": .array([history])])
            store.selectConversation("history")
            let readID = try XCTUnwrap(client.commands.last?["readId"]?.string)
            let snapshot = attachment()
            store.desktop.replaceAttachments([snapshot])
            store.setInputDraft("快速输入", for: .quickChat)
            XCTAssertTrue(store.ask(store.inputDraft(for: .quickChat), startsNewConversation: true))
            let id = store.selectedConversationID
            XCTAssertFalse(store.isLoadingConversation)
            XCTAssertNotEqual(client.commands.last?["conversationId"], .string("history"))
            XCTAssertEqual(store.conversation.first?.attachments, [snapshot])
            client.emit("conversation.messages", ["readId": .string(readID), "conversationId": .string("history"), "conversation": history])
            XCTAssertEqual(store.selectedConversationID, id)
            XCTAssertEqual(store.conversation.first?.prompt, "快速输入")
        }
    }

    func testArchivedHistoryDoesNotBlockANewQuickSession() async throws {
        try await withStore { store, client in
            let archived = session(archived: true)
            client.emit("agent.status", ["conversations": .array([archived])])
            try select(archived, store: store, client: client)
            XCTAssertFalse(store.ask("仍不能在归档会话继续"))
            XCTAssertTrue(store.ask("新的快速会话", startsNewConversation: true))
            XCTAssertNotEqual(client.commands.last?["conversationId"], .string("history"))
            XCTAssertTrue(try XCTUnwrap(store.sessions.first { $0.id == "history" }).archived)
            XCTAssertFalse(store.selectedConversationArchived)
        }
    }

    func testRunningSessionsSurviveBoardNavigationAndOlderSummariesBeforeAcknowledgement() async throws {
        try await withStore { store, client in
            XCTAssertTrue(store.ask("旧任务"))
            let oldID = try XCTUnwrap(store.selectedConversationID)
            let oldRequest = try XCTUnwrap(store.conversation.first?.id)
            XCTAssertTrue(store.ask("新任务", startsNewConversation: true, newConversationID: "invocation-id"))
            let newRequest = try XCTUnwrap(store.conversation.first?.id)
            client.emit("agent.status", ["conversations": .array([])])
            XCTAssertEqual(Set(store.sessions.map(\.id)), [oldID, "invocation-id"])
            store.newConversation()
            XCTAssertNil(store.selectedConversationID)
            XCTAssertTrue(store.hasPendingPrompt)
            XCTAssertFalse(store.selectedConversationHasPendingPrompt)
            store.selectConversation(oldID)
            XCTAssertEqual(store.conversation.first?.id, oldRequest)
            store.stopCurrentTask()
            XCTAssertEqual(client.commands.last?["conversationId"], .string(oldID))
            XCTAssertEqual(client.commands.last?["op"], .string("cancel"))
            client.emit("agent.error", ["requestId": .string(oldRequest), "conversationId": .string(oldID), "message": .string("已取消")])
            XCTAssertTrue(store.hasPendingPrompt)
            XCTAssertFalse(store.selectedConversationHasPendingPrompt)
            client.emit("agent.response", ["requestId": .string(newRequest), "conversationId": .string("invocation-id"), "text": .string("新任务继续完成")])
            XCTAssertFalse(store.hasPendingPrompt)
            XCTAssertEqual(store.conversation.first?.error, "已取消")
            XCTAssertEqual(store.sessions.first { $0.id == "invocation-id" }?.messages.first?.response, "新任务继续完成")
        }
    }

    func testFailedQuickSendPreservesTheStillRunningOldSessionAndDisconnectSettlesAll() async throws {
        try await withStore { store, client in
            XCTAssertTrue(store.ask("继续运行的旧任务"))
            let oldID = store.selectedConversationID
            let oldMessages = store.conversation
            client.failSend = true
            XCTAssertFalse(store.ask("新任务", startsNewConversation: true))
            XCTAssertEqual(store.selectedConversationID, oldID)
            XCTAssertEqual(store.conversation, oldMessages)
            XCTAssertTrue(store.hasPendingPrompt)
            client.failSend = false
            XCTAssertTrue(store.ask("新任务", startsNewConversation: true))
            client.onMessage?(.connection(.stopped))
            XCTAssertFalse(store.hasPendingPrompt)
            XCTAssertTrue(store.sessions.allSatisfy { $0.state == "failed" && $0.messages.allSatisfy { !$0.isPending } })
        }
    }

    func testHistoryReadFailureDoesNotBlockANewQuickSessionAndSendFailureRestoresIt() async throws {
        try await withStore { store, client in
            let history = session()
            client.emit("agent.status", ["conversations": .array([history])])
            store.selectConversation("history")
            let readID = try XCTUnwrap(client.commands.last?["readId"]?.string)
            client.emit("agent.error", ["readId": .string(readID), "message": .string("历史读取失败")])
            store.setInputDraft("旧会话未发文字", for: .conversation)
            store.setInputDraft("新的快速输入", for: .quickChat)
            let snapshot = attachment()
            store.desktop.replaceAttachments([snapshot])
            let previousMessages = store.conversation
            let previousSessions = store.sessions
            let commandCount = client.commands.count
            XCTAssertFalse(store.ask("历史继续仍需重试读取"))

            client.failSend = true
            XCTAssertFalse(store.ask(store.inputDraft(for: .quickChat), startsNewConversation: true))
            XCTAssertEqual(client.commands.count, commandCount)
            XCTAssertEqual(store.selectedConversationID, "history")
            XCTAssertEqual(store.conversation, previousMessages)
            XCTAssertEqual(store.sessions, previousSessions)
            XCTAssertEqual(store.conversationActionError, "历史读取失败")
            XCTAssertEqual(store.inputDraft(for: .conversation), "旧会话未发文字")
            XCTAssertEqual(store.inputDraft(for: .quickChat), "新的快速输入")
            XCTAssertEqual(store.desktop.attachments, [snapshot])
            XCTAssertFalse(store.hasPendingPrompt)

            client.failSend = false
            XCTAssertTrue(store.ask(store.inputDraft(for: .quickChat), startsNewConversation: true))
            XCTAssertNotEqual(client.commands.last?["conversationId"], .string("history"))
            XCTAssertNil(store.conversationActionError)
            XCTAssertEqual(store.conversation.map(\.prompt), ["新的快速输入"])
        }
    }

    func testDisconnectedAndUnconfiguredQuickSubmissionsKeepTheUnsentDraft() async throws {
        try await withStore { store, client in
            store.setInputDraft("看板草稿", for: .conversation)
            store.setInputDraft("临时草稿", for: .quickChat)
            let snapshot = attachment()
            store.desktop.replaceAttachments([snapshot])
            client.onMessage?(.connection(.stopped))
            XCTAssertFalse(store.ask(store.inputDraft(for: .quickChat), startsNewConversation: true))
            client.onMessage?(.connection(.connected))
            client.emit("agent.status", ["model": .object(["configured": .bool(false)])])
            XCTAssertFalse(store.ask(store.inputDraft(for: .quickChat), startsNewConversation: true))
            client.emit("agent.status", ["model": .object(["configured": .bool(true)])])
            client.failSend = true
            XCTAssertFalse(store.ask(store.inputDraft(for: .quickChat), startsNewConversation: true))

            XCTAssertNil(store.selectedConversationID)
            XCTAssertTrue(store.sessions.isEmpty)
            XCTAssertTrue(store.conversation.isEmpty)
            XCTAssertFalse(client.commands.contains { $0["op"] == .string("prompt") })
            XCTAssertEqual(store.inputDraft(for: .conversation), "看板草稿")
            XCTAssertEqual(store.inputDraft(for: .quickChat), "临时草稿")
            XCTAssertEqual(store.desktop.attachments, [snapshot])
        }
    }

    func testCaptureCompletionCanStartANewQuickSessionWithoutLosingTheSnapshot() async throws {
        let desktop = DesktopSession { mode, _ in
            DesktopCapture(imageData: Data([1, 2, 3]), mimeType: "image/png", context: ["appName": .string("Fixture")], mode: mode)
        }
        try await withStore(desktop: desktop) { store, client in
            let history = session()
            client.emit("agent.status", ["conversations": .array([history])])
            try select(history, store: store, client: client)
            var submitted = false
            desktop.capture(.window) {
                XCTAssertEqual(desktop.attachments.count, 1)
                submitted = store.ask("", startsNewConversation: true)
            }
            for _ in 0..<100 where desktop.isCapturing { try await Task.sleep(for: .milliseconds(5)) }
            XCTAssertTrue(submitted)
            XCTAssertNotEqual(client.commands.last?["conversationId"], .string("history"))
            XCTAssertEqual(client.commands.last?["prompt"], .string("请分析截图及应用上下文。"))
            XCTAssertEqual(client.commands.last?["attachments"]?.array?.count, 1)
            XCTAssertEqual(store.conversation.first?.attachments.first?.capture.imageData, Data([1, 2, 3]))
            XCTAssertTrue(desktop.attachments.isEmpty)
        }
    }
}
