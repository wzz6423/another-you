import ApplicationServices
import Foundation
import XCTest
@testable import AnotherYouCore

private struct TextNode: Sendable {
    var text: String
    var secure = false
    var children: [TextNode] = []
}

private struct FixtureAccessibility: ContextAccessibility {
    func string(_ attribute: String, from element: TextNode) -> String? { attribute == kAXValueAttribute ? element.text : nil }
    func protectedContent(_ element: TextNode) -> Bool { element.secure }
    func children(_ element: TextNode, limit: Int) -> [TextNode] { Array(element.children.prefix(limit)) }
}

private actor SuspendedCollector: ContextCollecting {
    private var continuation: CheckedContinuation<ContextSnapshot, Never>?
    private(set) var sources: [String] = []
    func collect(source: String) async -> ContextSnapshot {
        sources.append(source)
        return await withCheckedContinuation { continuation = $0 }
    }
    func complete() {
        continuation?.resume(returning: ContextSnapshot(status: "ok", content: ["text": .string("fixture")]))
        continuation = nil
    }
}

final class ContextCollectorTests: XCTestCase {
    func testSecureSubtreeIsExcludedAndTextIsBounded() {
        let root = TextNode(text: "标题", children: [TextNode(text: "密码", secure: true, children: [TextNode(text: "隐藏内容")]), TextNode(text: String(repeating: "文", count: 5000))])
        var reader = ContextTextReader(access: FixtureAccessibility(), remainingCharacters: 30, deadline: Date().addingTimeInterval(10))
        let text = reader.read(root).joined()
        XCTAssertEqual(text.count, 30)
        XCTAssertFalse(text.contains("密码"))
        XCTAssertFalse(text.contains("隐藏内容"))
    }

    func testTraversalStopsAtNodeAndTimeBudgets() {
        let root = TextNode(text: "root", children: (0..<100).map { TextNode(text: "node\($0)") })
        var reader = ContextTextReader(access: FixtureAccessibility(), remainingNodes: 2, deadline: Date().addingTimeInterval(10))
        XCTAssertEqual(reader.read(root), ["root", "node0"])
        var expired = ContextTextReader(access: FixtureAccessibility(), deadline: .distantPast)
        XCTAssertTrue(expired.read(root).isEmpty)
    }

    func testUnknownSourceDoesNotAttemptToReadDesktop() async {
        let result = await SystemContextCollector().collect(source: "unknown")
        XCTAssertEqual(result.status, "unavailable")
        XCTAssertTrue(result.content.isEmpty)
    }

    @MainActor
    func testAsyncCollectionReturnsCorrelatedResultWithoutBlockingMainActor() async {
        let collector = SuspendedCollector()
        let session = ProactiveContextSession(collector: collector)
        var replies: [[String: JSONValue]] = []
        session.handle(makeEvent("context.request", id: "request-1", source: "notifications")) { replies.append($0) }
        for _ in 0..<100 { if !(await collector.sources).isEmpty { break }; await Task.yield() }
        XCTAssertTrue(replies.isEmpty)
        XCTAssertTrue(session.isRunning)
        await collector.complete()
        for _ in 0..<100 { if !replies.isEmpty { break }; await Task.yield() }
        XCTAssertEqual(replies.first?["op"], .string("contextResult"))
        XCTAssertEqual(replies.first?["contextResult"]?.object?["requestId"], .string("request-1"))
        XCTAssertEqual(replies.first?["contextResult"]?.object?["source"], .string("notifications"))
    }

    @MainActor
    func testCancellationDropsLatePrivateResult() async {
        let collector = SuspendedCollector()
        let session = ProactiveContextSession(collector: collector)
        var replies: [[String: JSONValue]] = []
        session.handle(makeEvent("context.request", id: "old", source: "work")) { replies.append($0) }
        for _ in 0..<100 { if !(await collector.sources).isEmpty { break }; await Task.yield() }
        session.handle(makeEvent("context.cancel", id: "old", source: "work")) { replies.append($0) }
        await collector.complete()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(replies.isEmpty)
        XCTAssertFalse(session.isRunning)
    }

    @MainActor
    func testPermissionAndUnavailableStatusesRemainExplicit() {
        let session = ProactiveContextSession()
        session.update(["tasks": .object(["work": .object(["state": .string("permission-required")]), "notifications": .object(["state": .string("unavailable")])]), "enabled": .bool(false)])
        XCTAssertEqual(session.stateLabel("work"), AppLocalization.text("需要辅助功能权限"))
        XCTAssertEqual(session.stateLabel("notifications"), AppLocalization.text("来源暂不可访问"))
        XCTAssertFalse(session.enabled)
    }

    private func makeEvent(_ kind: String, id: String, source: String) -> AgentEvent {
        AgentEvent(id: UUID().uuidString, occurredAt: "2026-10-01T12:00:00Z", kind: kind, source: "scheduler", payload: ["requestId": .string(id), "source": .string(source)])
    }
}
