import Foundation
import XCTest
@testable import AnotherYouCore

@MainActor
private final class DesktopTestClient: AgentClient {
    var onMessage: (@MainActor @Sendable (AgentClientMessage) -> Void)?
    var commands: [[String: JSONValue]] = []
    func start(configURL: URL) throws { }
    func send(_ command: [String: JSONValue]) throws { commands.append(command) }
    func stop() async { onMessage?(.connection(.stopped)) }
    func emit(_ kind: String, payload: [String: JSONValue]) {
        onMessage?(.event(AgentEvent(id: UUID().uuidString, occurredAt: "2026-10-01T10:00:00.000Z", kind: kind, source: "agent", payload: payload)))
    }
}

@MainActor
final class DesktopSessionTests: XCTestCase {
    func testNativeRepliesStayOutOfHistoryAndForegroundIsRejectedBeforeExecution() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("another-you-desktop-session-\(UUID())")
        let domain = "another-you-desktop-session-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain); try? FileManager.default.removeItem(at: directory) }
        let client = DesktopTestClient()
        let store = AssistantStore(client: client, repository: AgentSettingsRepository(dataDirectory: directory), defaults: defaults)
        client.emit("desktop.request", payload: ["requestId": .string("capabilities"), "arguments": .object(["action": .string("capabilities")])])
        for _ in 0..<100 where !client.commands.contains(where: { $0["requestId"]?.string == "capabilities" }) { try await Task.sleep(for: .milliseconds(5)) }
        let reply = try XCTUnwrap(client.commands.first { $0["requestId"]?.string == "capabilities" })
        XCTAssertEqual(reply["op"], .string("desktopResult"))
        XCTAssertEqual(reply["result"]?.object?["platform"], .string("macOS"))
        XCTAssertTrue(store.history.isEmpty)
        client.emit("desktop.request", payload: ["requestId": .string("forbidden"), "arguments": .object(["action": .string("type"), "background": .bool(false), "text": .string("must-not-type")])])
        XCTAssertEqual(client.commands.last?["error"], .string(AppLocalization.text("前台控制未开启。")))
        XCTAssertTrue(store.history.isEmpty)
        await store.shutdown()
    }

    func testPromptCarriesModeAndCancelIsDeliveredWithoutLosingPendingState() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("another-you-desktop-session-\(UUID())")
        let domain = "another-you-desktop-session-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain); try? FileManager.default.removeItem(at: directory) }
        let client = DesktopTestClient()
        let store = AssistantStore(client: client, repository: AgentSettingsRepository(dataDirectory: directory), defaults: defaults)
        client.onMessage?(.connection(.connected))
        client.emit("agent.status", payload: ["model": .object(["configured": .bool(true)])])
        XCTAssertTrue(store.ask("测试任务"))
        XCTAssertEqual(client.commands.last?["allowForeground"], .bool(false))
        XCTAssertTrue(store.hasPendingPrompt)
        store.stopCurrentTask()
        XCTAssertEqual(client.commands.last?["op"], .string("cancel"))
        XCTAssertTrue(store.hasPendingPrompt)
        client.emit("agent.error", payload: ["requestId": .string(try XCTUnwrap(store.conversation.first?.id)), "message": .string("已取消")])
        XCTAssertFalse(store.hasPendingPrompt)
        await store.shutdown()
    }

    func testScreenshotAttachmentKeepsBinarySeparateFromContext() throws {
        let capture = DesktopCapture(imageData: Data([255, 216, 255]), mimeType: "image/jpeg", context: ["appName": .string("Fixture")], mode: .window)
        let attachment = ScreenAttachment(capture: capture)
        XCTAssertEqual(attachment.payload.object?["data"], .string("/9j/"))
        XCTAssertEqual(attachment.payload.object?["context"]?.object?["appName"], .string("Fixture"))
        let message = ConversationMessage(id: "test", prompt: "截图", attachments: [attachment])
        XCTAssertEqual(message.attachments.first?.capture, capture)
    }

    func testPromptCarriesInvocationSnapshotWithoutLeakingIntoFollowingMainConversation() async throws {
        let domain = "another-you-invocation-prompt-\(UUID())"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(domain)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defaults.set(false, forKey: "notificationsEnabled")
        defer { defaults.removePersistentDomain(forName: domain); try? FileManager.default.removeItem(at: directory) }
        let client = DesktopTestClient()
        let store = AssistantStore(client: client, repository: AgentSettingsRepository(dataDirectory: directory), defaults: defaults,
                                   updater: UpdateController(driver: nil, defaults: defaults))
        client.onMessage?(.connection(.connected))
        client.emit("agent.status", payload: ["model": .object(["configured": .bool(true)])])
        let snapshot: [String: JSONValue] = ["capturedAt": .string("2026-10-07T10:00:00Z"),
            "context": .object(["pid": .number(4242), "title": .string("唤起时的窗口")]),
            "image": .object(["data": .string("/9j/"), "mimeType": .string("image/jpeg")]), "mode": .string("screen")]
        XCTAssertTrue(store.ask("阅读一下屏幕", startsNewConversation: true, desktopSnapshot: snapshot))
        XCTAssertEqual(client.commands.last?["desktopSnapshot"], .object(snapshot))
        XCTAssertEqual(client.commands.last?["attachments"], .array([]))
        let id = try XCTUnwrap(store.conversation.first?.id)
        client.emit("agent.response", payload: ["requestId": .string(id), "text": .string("完成")])
        XCTAssertTrue(store.ask("从主窗口继续"))
        XCTAssertNil(client.commands.last?["desktopSnapshot"])
        await store.shutdown()
    }
}
