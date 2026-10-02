import AppKit
import Foundation
import XCTest
@testable import AnotherYouCore

@MainActor
private final class BoardTestClient: AgentClient {
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
        onMessage?(.event(AgentEvent(id: UUID().uuidString, occurredAt: ISO8601DateFormatter().string(from: Date()), kind: kind, source: "agent", payload: payload)))
    }
}

@MainActor
final class ConversationBoardTests: XCTestCase {
    private func session(_ id: String = "session", archived: Bool = false) -> JSONValue {
        .object(["id": .string(id), "title": .string("测试会话"), "appName": .string("Fixture"),
                 "state": .string("completed"), "archived": .bool(archived), "updatedAt": .string("2026-10-02T04:00:00Z"),
                 "messages": .array([.object(["id": .string("turn"), "prompt": .string("历史输入"), "response": .string("历史回复")])])])
    }

    private func withStore(_ body: (AssistantStore, BoardTestClient) async throws -> Void) async throws {
        let domain = "another-you-board-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(domain)
        defer { defaults.removePersistentDomain(forName: domain); try? FileManager.default.removeItem(at: directory) }
        let client = BoardTestClient()
        let store = AssistantStore(client: client, repository: AgentSettingsRepository(dataDirectory: directory), defaults: defaults)
        client.onMessage?(.connection(.connected))
        client.emit("agent.status", ["model": .object(["configured": .bool(true)])])
        do { try await body(store, client) } catch { await store.shutdown(); throw error }
        await store.shutdown()
    }

    func testArchiveWaitsForSidecarAcknowledgementAndFailureLeavesSessionUnchanged() async throws {
        try await withStore { store, client in
            client.emit("agent.status", ["conversations": .array([session()])])
            store.manageConversation("session", action: "archive")
            XCTAssertEqual(client.commands.last?["op"], .string("conversationAction"))
            XCTAssertFalse(store.sessions[0].archived)
            XCTAssertTrue(store.pendingConversationActions.contains("session"))
            client.emit("agent.error", ["conversationId": .string("session"), "message": .string("fixture rejected")])
            XCTAssertFalse(store.sessions[0].archived)
            XCTAssertTrue(store.pendingConversationActions.isEmpty)
            XCTAssertEqual(store.conversationActionError, "fixture rejected")
            store.manageConversation("session", action: "archive")
            client.emit("conversation.updated", ["conversationId": .string("session"), "action": .string("archive"), "conversations": .array([session(archived: true)])])
            XCTAssertTrue(store.sessions[0].archived)
            XCTAssertTrue(store.pendingConversationActions.isEmpty)
        }
    }

    func testRestoredSessionCanBeSelectedAndFollowupUsesSameIdentifier() async throws {
        try await withStore { store, client in
            client.emit("agent.status", ["conversations": .array([session()])])
            XCTAssertEqual(store.sessions[0].appName, "Fixture")
            store.selectConversation("session")
            XCTAssertTrue(store.isLoadingConversation)
            let readID = try XCTUnwrap(client.commands.last?["readId"]?.string)
            client.emit("conversation.messages", ["readId": .string(readID), "conversationId": .string("session"), "conversation": session()])
            XCTAssertFalse(store.isLoadingConversation)
            XCTAssertEqual(store.conversation[0].response, "历史回复")
            XCTAssertTrue(store.ask("继续"))
            XCTAssertEqual(client.commands.last?["conversationId"], .string("session"))
            let requestID = try XCTUnwrap(client.commands.last?["requestId"]?.string)
            client.emit("agent.response", ["requestId": .string(requestID), "text": .string("已完成")])
            store.newConversation()
            XCTAssertTrue(store.conversation.isEmpty)
            XCTAssertTrue(store.ask("新的话题"))
            XCTAssertNotEqual(client.commands.last?["conversationId"], .string("session"))
        }
    }

    func testArchivedReadOnlyAndDeletionClearSelectedMessagesAfterReceipt() async throws {
        try await withStore { store, client in
            client.emit("agent.status", ["conversations": .array([session(archived: true)])])
            store.selectConversation("session")
            XCTAssertTrue(store.selectedConversationArchived)
            XCTAssertFalse(store.ask("不应发送"))
            store.manageConversation("session", action: "delete")
            XCTAssertEqual(store.conversation.count, 1)
            client.emit("conversation.updated", ["conversationId": .string("session"), "action": .string("delete"), "conversations": .array([])])
            XCTAssertNil(store.selectedConversationID)
            XCTAssertTrue(store.conversation.isEmpty)
            XCTAssertTrue(store.sessions.isEmpty)
        }
    }

    func testLiveAndRestoredActivityUsesTheSameCategoryWithoutRecordingRawDesktopRequests() async throws {
        try await withStore { store, client in
            client.emit("agent.activity", ["category": .string("thinking"), "phase": .string("started")])
            client.emit("agent.activity", ["category": .string("command"), "phase": .string("completed"), "toolName": .string("shell")])
            client.emit("agent.activity", ["category": .string("context"), "phase": .string("started")])
            client.emit("unknown.event", [:])
            XCTAssertEqual(Set(store.activityHistory.compactMap(\.activityCategory)), Set([.thinking, .command, .context]))
            XCTAssertEqual(store.activityHistory.count, 3)
        }
    }

    func testReadRestoresSummaryAndIgnoresStaleResponse() async throws {
        try await withStore { store, client in
            var summary = try XCTUnwrap(session().object)
            summary.removeValue(forKey: "messages")
            client.emit("agent.status", ["conversations": .array([.object(summary)])])
            store.selectConversation("session")
            XCTAssertTrue(store.conversation.isEmpty)
            let readID = try XCTUnwrap(client.commands.last?["readId"]?.string)
            client.emit("conversation.messages", ["readId": .string("stale"), "conversationId": .string("session"), "conversation": .null])
            XCTAssertTrue(store.isLoadingConversation)
            XCTAssertTrue(store.conversation.isEmpty)
            client.emit("conversation.messages", ["readId": .string(readID), "conversationId": .string("session"), "conversation": session()])
            XCTAssertFalse(store.isLoadingConversation)
            XCTAssertEqual(store.conversation[0].response, "历史回复")
            client.emit("agent.status", ["conversations": .array([.object(summary)])])
            XCTAssertEqual(store.conversation[0].response, "历史回复")
        }
    }

    func testStaleStatusCannotDropAnUnacknowledgedPrompt() async throws {
        try await withStore { store, client in
            XCTAssertTrue(store.ask("已提交消息"))
            let id = try XCTUnwrap(store.selectedConversationID)
            let request = try XCTUnwrap(store.conversation.first?.id)
            client.emit("agent.status", ["conversations": .array([])])
            XCTAssertEqual(store.selectedConversationID, id)
            XCTAssertTrue(store.hasPendingPrompt)
            client.emit("agent.response", ["requestId": .string(request), "text": .string("回复")])
            XCTAssertEqual(store.conversation.first?.response, "回复")
        }
    }

    func testForegroundSnapshotUsesWindowCaptureAndRetainsPreviewBeforeSending() async throws {
        var modes: [DesktopCaptureMode] = []
        let desktop = DesktopSession { mode, _ in
            modes.append(mode)
            return DesktopCapture(imageData: Data([255, 216, 255]), mimeType: "image/jpeg", context: ["appName": .string("Fixture")], mode: mode)
        }
        desktop.capture(.window)
        for _ in 0..<100 where desktop.isCapturing { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(modes.count, 1)
        XCTAssertEqual(modes.first, .window)
        XCTAssertEqual(desktop.attachments.count, 1)
        XCTAssertEqual(desktop.attachments[0].capture.context["appName"], .string("Fixture"))
        XCTAssertFalse(desktop.allowForeground)
        desktop.clearAttachments()
        desktop.cancel()
    }

    func testNewConversationIsLocalUntilSendAndDraftsStayWithTheirConversation() async throws {
        try await withStore { store, client in
            client.emit("agent.status", ["conversations": .array([session("a"), session("b")])])
            XCTAssertNil(store.selectedConversationID)
            store.setInputDraft("新会话草稿", for: .conversation)
            let newAttachment = ScreenAttachment(capture: DesktopCapture(imageData: Data([1]), mimeType: "image/png", context: [:], mode: .window))
            let sourceAttachment = ScreenAttachment(capture: DesktopCapture(imageData: Data([2]), mimeType: "image/png", context: [:], mode: .screen))
            store.desktop.replaceAttachments([newAttachment])
            let before = client.commands.count
            store.newConversation()
            XCTAssertEqual(client.commands.count, before)
            store.selectConversation("a")
            XCTAssertEqual(store.inputDraft(for: .conversation), "")
            XCTAssertTrue(store.desktop.attachments.isEmpty)
            store.setInputDraft("A 的续聊", for: .conversation)
            store.desktop.replaceAttachments([sourceAttachment])
            store.selectConversation("b")
            XCTAssertEqual(store.inputDraft(for: .conversation), "")
            XCTAssertTrue(store.desktop.attachments.isEmpty)
            store.setInputDraft("B 的续聊", for: .conversation)
            store.selectConversation("a")
            XCTAssertEqual(store.inputDraft(for: .conversation), "A 的续聊")
            XCTAssertEqual(store.desktop.attachments, [sourceAttachment])
            store.newConversation()
            XCTAssertEqual(store.inputDraft(for: .conversation), "新会话草稿")
            XCTAssertEqual(store.desktop.attachments, [newAttachment])
            XCTAssertEqual(store.sessions.count, 2)
        }
    }

    func testSwitchingDraftCancelsCaptureBeforeItCanAttachToAnotherConversation() async throws {
        let desktop = DesktopSession { _, _ in
            try await Task.sleep(for: .milliseconds(30))
            return DesktopCapture(imageData: Data([1]), mimeType: "image/png", context: [:], mode: .window)
        }
        desktop.capture(.window)
        XCTAssertTrue(desktop.isCapturing)
        let saved = ScreenAttachment(capture: DesktopCapture(imageData: Data([2]), mimeType: "image/png", context: [:], mode: .screen))
        desktop.replaceAttachments([saved])
        for _ in 0..<100 where desktop.isCapturing { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(desktop.isCapturing)
        XCTAssertEqual(desktop.attachments, [saved])
        desktop.cancel()
    }

    func testForkSelectsOnlyMatchingSuccessfulReceiptThenReadsFullMessages() async throws {
        try await withStore { store, client in
            client.emit("agent.status", ["conversations": .array([session()])])
            store.selectConversation("session")
            let readID = try XCTUnwrap(client.commands.last?["readId"]?.string)
            client.emit("conversation.messages", ["readId": .string(readID), "conversationId": .string("session"), "conversation": session()])
            store.setInputDraft("源会话草稿", for: .conversation)
            let sourceAttachment = ScreenAttachment(capture: DesktopCapture(imageData: Data([3]), mimeType: "image/png", context: [:], mode: .window))
            store.desktop.replaceAttachments([sourceAttachment])
            XCTAssertTrue(store.canForkConversation)
            store.forkConversation(through: "turn")
            let requestID = try XCTUnwrap(client.commands.last?["requestId"]?.string)
            XCTAssertEqual(client.commands.last?["messageId"], .string("turn"))
            XCTAssertEqual(store.selectedConversationID, "session")
            XCTAssertFalse(store.canForkConversation)
            XCTAssertFalse(store.ask("分支期间不能发送"))
            var fork = try XCTUnwrap(session("branch").object)
            fork["forkedFrom"] = .object(["conversationId": .string("session"), "messageId": .string("turn")])
            fork.removeValue(forKey: "messages")
            let values: [JSONValue] = [session(), .object(fork)]
            client.emit("conversation.updated", ["action": .string("fork"), "requestId": .string("stale"), "sourceConversationId": .string("session"), "conversationId": .string("branch"), "conversations": .array(values)])
            XCTAssertEqual(store.selectedConversationID, "session")
            XCTAssertTrue(store.pendingConversationActions.contains("session"))
            client.emit("conversation.updated", ["action": .string("fork"), "requestId": .string(requestID), "sourceConversationId": .string("session"), "conversationId": .string("branch"), "conversations": .array(values)])
            XCTAssertEqual(store.selectedConversationID, "branch")
            XCTAssertEqual(store.inputDraft(for: .conversation), "")
            XCTAssertTrue(store.desktop.attachments.isEmpty)
            XCTAssertTrue(store.isLoadingConversation)
            XCTAssertTrue(store.conversation.isEmpty)
            XCTAssertEqual(store.sessions.first { $0.id == "branch" }?.forkedFrom?.messageID, "turn")
            let branchRead = try XCTUnwrap(client.commands.last?["readId"]?.string)
            client.emit("conversation.messages", ["readId": .string(branchRead), "conversationId": .string("branch"), "conversation": session("branch")])
            XCTAssertFalse(store.isLoadingConversation)
            XCTAssertEqual(store.conversation.first?.response, "历史回复")
            store.selectConversation("session")
            XCTAssertEqual(store.inputDraft(for: .conversation), "源会话草稿")
            XCTAssertEqual(store.desktop.attachments, [sourceAttachment])
        }
    }

    func testForkFailureAndDisconnectKeepOriginalAndUnlockControls() async throws {
        try await withStore { store, client in
            client.emit("agent.status", ["conversations": .array([session()])])
            @MainActor func load() throws {
                store.selectConversation("session")
                let readID = try XCTUnwrap(client.commands.last?["readId"]?.string)
                client.emit("conversation.messages", ["readId": .string(readID), "conversationId": .string("session"), "conversation": session()])
            }
            try load()
            store.forkConversation()
            let requestID = try XCTUnwrap(client.commands.last?["requestId"]?.string)
            client.emit("agent.error", ["requestId": .string(requestID), "conversationId": .string("session"), "message": .string("保存失败")])
            XCTAssertEqual(store.selectedConversationID, "session")
            XCTAssertEqual(store.conversation.first?.response, "历史回复")
            XCTAssertTrue(store.pendingConversationActions.isEmpty)
            XCTAssertEqual(store.conversationActionError, "保存失败")
            try load()
            store.forkConversation()
            client.onMessage?(.connection(.stopped))
            XCTAssertEqual(store.selectedConversationID, "session")
            XCTAssertTrue(store.pendingConversationActions.isEmpty)
            client.onMessage?(.connection(.connected))
            try load()
            client.failSend = true
            store.forkConversation()
            XCTAssertTrue(store.pendingConversationActions.isEmpty)
            XCTAssertNotNil(store.conversationActionError)
        }
    }

    func testArchiveRestoreAllowsDetailContinuationOnlyAfterReceipt() async throws {
        try await withStore { store, client in
            client.emit("agent.status", ["conversations": .array([session(archived: true)])])
            store.selectConversation("session")
            let readID = try XCTUnwrap(client.commands.last?["readId"]?.string)
            client.emit("conversation.messages", ["readId": .string(readID), "conversationId": .string("session"), "conversation": session(archived: true)])
            store.manageConversation("session", action: "unarchive")
            XCTAssertFalse(store.ask("恢复尚未确认"))
            client.emit("conversation.updated", ["conversationId": .string("session"), "action": .string("unarchive"), "conversations": .array([session()])])
            XCTAssertTrue(store.ask("确认后继续"))
            XCTAssertEqual(client.commands.last?["conversationId"], .string("session"))
        }
    }
}

final class ModifierChordTests: XCTestCase {
    func testControlOptionTriggersOnceAfterBothModifiersAreReleased() {
        var chord = ModifierChord()
        XCTAssertFalse(chord.consume(type: .flagsChanged, flags: [.control]))
        XCTAssertFalse(chord.consume(type: .flagsChanged, flags: [.control, .option]))
        XCTAssertFalse(chord.consume(type: .flagsChanged, flags: [.control]))
        XCTAssertTrue(chord.consume(type: .flagsChanged, flags: []))
        XCTAssertFalse(chord.consume(type: .flagsChanged, flags: []))
    }

    func testOtherShortcutsDoNotCaptureAndTypingDoesNotDisableTheNextChord() {
        var chord = ModifierChord()
        XCTAssertFalse(chord.consume(type: .keyDown, flags: []))
        XCTAssertFalse(chord.consume(type: .flagsChanged, flags: [.control, .option]))
        XCTAssertTrue(chord.consume(type: .flagsChanged, flags: []))
        XCTAssertFalse(chord.consume(type: .flagsChanged, flags: [.control, .option]))
        XCTAssertFalse(chord.consume(type: .keyDown, flags: [.control, .option]))
        XCTAssertFalse(chord.consume(type: .flagsChanged, flags: []))
        XCTAssertFalse(chord.consume(type: .flagsChanged, flags: [.control, .option, .shift]))
        XCTAssertFalse(chord.consume(type: .flagsChanged, flags: [.control, .option]))
        XCTAssertFalse(chord.consume(type: .flagsChanged, flags: []))
    }
}
