import AppKit
import Combine
import XCTest
@testable import AnotherYouCore

@MainActor
private final class RenderingAgentClient: AgentClient {
    var onMessage: (@MainActor @Sendable (AgentClientMessage) -> Void)?
    func start(configURL: URL) throws {}
    func send(_ command: [String: JSONValue]) throws {}
    func stop() async {}

    func status(_ payload: [String: JSONValue], at date: String = "2026-10-01T10:00:00Z") {
        onMessage?(.event(AgentEvent(id: UUID().uuidString, occurredAt: date, kind: "agent.status", source: "system", payload: payload)))
    }
}

@MainActor
final class RenderingTests: XCTestCase {
    private func withStore(_ test: (AssistantStore, RenderingAgentClient) throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("another-you-rendering-\(UUID().uuidString)")
        let suite = "another-you-rendering-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let client = RenderingAgentClient()
        let store = AssistantStore(client: client, repository: AgentSettingsRepository(dataDirectory: directory), defaults: defaults,
                                   updater: UpdateController(driver: nil, defaults: defaults))
        do { try test(store, client) }
        catch { await store.shutdown(); throw error }
        await store.shutdown()
    }

    func testDraftEditsPublishOnlyToTheirInputAndKeepUpdateGate() async throws {
        try await withStore { store, _ in
            let conversation = store.draft(for: .conversation)
            let quickChat = store.draft(for: .quickChat)
            XCTAssertTrue(conversation === store.draft(for: .conversation))
            XCTAssertTrue(store.canInstallUpdate)
            var rootChanges = 0, conversationChanges = 0, quickChatChanges = 0
            let observers = [
                store.objectWillChange.sink { rootChanges += 1 },
                conversation.$text.dropFirst().sink { _ in conversationChanges += 1 },
                quickChat.$text.dropFirst().sink { _ in quickChatChanges += 1 }
            ]
            defer { observers.forEach { $0.cancel() } }
            for length in 1...120 { store.setInputDraft(String(repeating: "字", count: length), for: .conversation) }
            store.setInputDraft("快速会话草稿", for: .quickChat)
            store.setInputDraft("快速会话草稿", for: .quickChat)
            XCTAssertEqual(rootChanges, 0)
            XCTAssertEqual(conversationChanges, 120)
            XCTAssertEqual(quickChatChanges, 1)
            XCTAssertEqual(conversation.text.count, 120)
            XCTAssertEqual(store.inputDraft(for: .quickChat), "快速会话草稿")
            XCTAssertFalse(store.canInstallUpdate)
            store.setInputDraft("", for: .conversation)
            XCTAssertFalse(store.canInstallUpdate)
            XCTAssertEqual(quickChat.text, "快速会话草稿")
            store.setInputDraft("", for: .quickChat)
            XCTAssertTrue(store.canInstallUpdate)
            XCTAssertEqual(rootChanges, 0)
        }
    }

    func testRepeatedStatusDoesNotRepublishCollectionsOrUnchangedState() async throws {
        try await withStore { store, client in
            let payload = statusPayload(tokens: 100)
            client.status(payload)
            var rootChanges = 0, cardChanges = 0, historyChanges = 0, usageChanges = 0
            let observers = [
                store.objectWillChange.sink { rootChanges += 1 },
                store.$cards.dropFirst().sink { _ in cardChanges += 1 },
                store.$history.dropFirst().sink { _ in historyChanges += 1 },
                store.$usageRecords.dropFirst().sink { _ in usageChanges += 1 }
            ]
            defer { observers.forEach { $0.cancel() } }
            for _ in 0..<50 { client.status(payload) }
            XCTAssertEqual(rootChanges, 0)
            client.status(payload, at: "2026-10-01T10:00:01Z")
            XCTAssertEqual(rootChanges, 1)
            XCTAssertEqual(cardChanges, 0)
            XCTAssertEqual(historyChanges, 0)
            XCTAssertEqual(usageChanges, 0)
            XCTAssertEqual(store.cards.count, 1)
            XCTAssertEqual(store.history.count, 1)
            XCTAssertEqual(store.usageRecords.count, 1)
        }
    }

    func testStatusCorrectionWithSameUsageIDStillPublishes() async throws {
        try await withStore { store, client in
            client.status(statusPayload(tokens: 100))
            var changes = 0
            let observer = store.$usageRecords.dropFirst().sink { _ in changes += 1 }
            defer { observer.cancel() }
            client.status(statusPayload(tokens: 250))
            XCTAssertEqual(changes, 1)
            XCTAssertEqual(store.usageRecords.first?.id, "usage")
            XCTAssertEqual(store.usageRecords.first?.usage?.totalTokens, 250)
        }
    }

    func testNestedSessionsPublishWithoutInvalidatingTheStore() async throws {
        try await withStore { store, _ in
            var rootChanges = 0, desktopChanges = 0, contextChanges = 0, updateChanges = 0
            let observers = [
                store.objectWillChange.sink { rootChanges += 1 },
                store.desktop.objectWillChange.sink { desktopChanges += 1 },
                store.proactiveContext.objectWillChange.sink { contextChanges += 1 },
                store.updates.objectWillChange.sink { updateChanges += 1 }
            ]
            defer { observers.forEach { $0.cancel() } }
            store.desktop.allowForeground = true
            store.proactiveContext.update(["running": .bool(true), "enabled": .bool(false)])
            store.updates.setAutomaticChecks(true)
            XCTAssertEqual(rootChanges, 0)
            XCTAssertGreaterThan(desktopChanges, 0)
            XCTAssertGreaterThan(contextChanges, 0)
            XCTAssertGreaterThan(updateChanges, 0)
            XCTAssertTrue(store.desktop.allowForeground)
            XCTAssertTrue(store.proactiveContext.isRunning)
            XCTAssertTrue(store.updates.automaticallyChecks)
        }
    }

    func testScreenshotPreviewIsDownsampledAndReusedByAttachmentID() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 1200, height: 800, bitsPerComponent: 8, bytesPerRow: 0,
                                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1200, height: 800))
        let source = try XCTUnwrap(context.makeImage())
        let data = try XCTUnwrap(NSBitmapImageRep(cgImage: source).representation(using: .png, properties: [:]))
        let capture = DesktopCapture(imageData: data, mimeType: "image/png", context: [:], mode: .screen)
        let attachment = ScreenAttachment(capture: capture)
        let cache = ConversationImageCache()
        let first = try XCTUnwrap(cache.image(for: attachment))
        let second = try XCTUnwrap(cache.image(for: attachment))
        XCTAssertTrue(first === second)
        let representation = try XCTUnwrap(first.representations.first)
        XCTAssertEqual(representation.pixelsWide, 280)
        XCTAssertLessThanOrEqual(representation.pixelsHigh, 280)
        let different = try XCTUnwrap(cache.image(for: ScreenAttachment(capture: capture)))
        XCTAssertFalse(first === different)
        let invalid = ScreenAttachment(capture: DesktopCapture(imageData: Data(), mimeType: "image/png", context: [:], mode: .screen))
        XCTAssertNil(cache.image(for: invalid))
    }

    func testUsageSnapshotKeepsBoundariesTotalsAndGroupsConsistent() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let formatter = ISO8601DateFormatter()
        let usage = UsageRecord.Tokens(inputTokens: 8, outputTokens: 4, cacheReadTokens: 3, cacheWriteTokens: 1, totalTokens: 16)
        func record(_ id: String, at date: Date, model: String = "model-a", usage: UsageRecord.Tokens? = usage,
                    outcome: String = "completed", effort: String = "high", tools: [UsageRecord.ToolCall] = []) -> UsageRecord {
            UsageRecord(id: id, occurredAt: formatter.string(from: date), source: "prompt", model: model,
                        outcome: outcome, usage: usage, reasoningEffort: effort, toolCalls: tools)
        }
        for period in UsagePeriod.allCases {
            let cutoff = now.addingTimeInterval(-period.seconds)
            let edge = record("edge", at: cutoff, model: "model-b", outcome: "failed", tools: [.init(name: "read", kind: "tool")])
            let records = [edge, edge,
                           record("current", at: now, tools: [.init(name: "read", kind: "mcp")]),
                           record("unknown", at: now, usage: nil, effort: "unknown"),
                           record("expired", at: cutoff.addingTimeInterval(-1)),
                           record("future", at: now.addingTimeInterval(1))]
            let summary = UsageSummary(records: records, period: period, now: now)
            XCTAssertEqual(summary.records.map(\.id), ["edge", "current", "unknown"])
            XCTAssertEqual(summary.knownCount, 2)
            XCTAssertEqual(summary.unknownCount, 1)
            XCTAssertEqual(summary.totalTokens, 32)
            XCTAssertEqual(summary.inputTokens, 16)
            XCTAssertEqual(summary.outputTokens, 8)
            XCTAssertEqual(summary.cacheTokens, 8)
            XCTAssertEqual(summary.failedCount, 1)
            XCTAssertEqual(summary.models.map(\.name), ["model-a", "model-b"])
            XCTAssertEqual(summary.models.map(\.count), [16, 16])
            XCTAssertEqual(summary.reasoning.map(\.count), [2, 1])
            XCTAssertEqual(summary.tools.map(\.name), ["mcp · read", "tool · read"])
            XCTAssertEqual(summary.tools.map(\.count), [1, 1])
            let later = UsageSummary(records: records, period: period, now: now.addingTimeInterval(1))
            XCTAssertFalse(later.records.contains { $0.id == "edge" })
            XCTAssertTrue(later.records.contains { $0.id == "future" })
        }
    }

    private func statusPayload(tokens: Double) -> [String: JSONValue] {
        ["paused": .bool(false), "model": .object(["configured": .bool(true), "model": .string("test-model")]),
         "proactive": .object(["running": .bool(false)]),
         "proposals": .array([.object(["id": .string("proposal"), "title": .string("建议"), "state": .string("pending"),
                                        "createdAt": .string("2026-10-01T09:00:00Z")])]),
         "history": .array([.object(["id": .string("history"), "kind": .string("agent.response"), "source": .string("agent"),
                                     "occurredAt": .string("2026-10-01T09:00:00Z"), "payload": .object(["text": .string("回复")])])]),
         "usageRecords": .array([.object(["id": .string("usage"), "occurredAt": .string("2026-10-01T09:00:00Z"),
                                          "source": .string("prompt"), "model": .string("test-model"), "outcome": .string("completed"),
                                          "reasoningEffort": .string("high"), "toolCalls": .array([]),
                                          "usage": .object(["inputTokens": .number(tokens), "outputTokens": .number(0),
                                                            "cacheReadTokens": .number(0), "cacheWriteTokens": .number(0),
                                                            "totalTokens": .number(tokens)])])])]
    }
}
