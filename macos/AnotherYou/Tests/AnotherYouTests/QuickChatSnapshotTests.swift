import Foundation
import XCTest
@testable import AnotherYouCore

@MainActor
private final class SnapshotFixture {
    var pid: pid_t? = 4242
    var title = "唤起时的窗口"
    var image = Data([255, 216, 255])
    var captureError: DesktopAutomationError?
    var capturedContexts: [[String: JSONValue]] = []
    var pending: [(pid_t?, DesktopCapture, CheckedContinuation<DesktopCapture, Never>)] = []

    func session() -> DesktopSession {
        DesktopSession(capture: { [self] mode, pid in
            if let captureError { throw captureError }
            let capture = DesktopCapture(imageData: image, mimeType: "image/jpeg", context: [:], mode: mode)
            return await withCheckedContinuation { pending.append((pid, capture, $0)) }
        }, snapshotCapture: { [self] pid, context in
            capturedContexts.append(context)
            if let captureError { throw captureError }
            let capture = DesktopCapture(imageData: image, mimeType: "image/jpeg", context: [:], mode: .window)
            return await withCheckedContinuation { pending.append((pid, capture, $0)) }
        }, context: { [self] pid in
            ["pid": .number(Double(pid)), "targetId": .string("target-\(pid)-\(title)"), "windowId": .number(Double(pid)),
             "appName": .string("测试应用"), "title": .string(title),
             "tree": .object(["value": .string(title)])]
        }, frontmostPID: { [self] in pid })
    }

    func complete(_ index: Int) { pending[index].2.resume(returning: pending[index].1) }
}

@MainActor
final class QuickChatSnapshotTests: XCTestCase {
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("等待快照状态超时")
    }

    func testCaptureCompletesBeforePresentationAndRemainsFrozenAfterSwitchingApplication() async throws {
        let fixture = SnapshotFixture()
        let desktop = fixture.session()
        let controller = QuickChatController()
        var presented = false
        controller.prepareInvocation(using: desktop) { presented = true }
        try await waitUntil { fixture.pending.count == 1 }
        XCTAssertFalse(presented)
        XCTAssertTrue(desktop.isPreparingSnapshot)
        XCTAssertNil(controller.desktopSnapshot)
        fixture.pid = 4343
        fixture.title = "后来切换的窗口"
        fixture.image = Data([1, 2, 3])
        desktop.rememberCurrentApplication()
        fixture.complete(0)
        try await waitUntil { presented }
        let snapshot = try XCTUnwrap(controller.desktopSnapshot)
        XCTAssertEqual(fixture.pending.first?.0, 4242)
        XCTAssertEqual(snapshot["context"]?.object?["pid"], .number(4242))
        XCTAssertEqual(snapshot["context"]?.object?["title"], .string("唤起时的窗口"))
        XCTAssertEqual(snapshot["image"]?.object?["data"], .string("/9j/"))
        XCTAssertEqual(snapshot["mode"], .string("window"))
        XCTAssertEqual(fixture.capturedContexts.first?["targetId"], snapshot["context"]?.object?["targetId"])
        XCTAssertEqual(fixture.capturedContexts.first?["windowId"], .number(4242))
        XCTAssertTrue(desktop.attachments.isEmpty)
        XCTAssertFalse(desktop.isPreparingSnapshot)
        controller.close()
        XCTAssertNil(controller.desktopSnapshot)
    }

    func testTextSnapshotIsTakenSynchronouslyEvenWhenTheSameApplicationChangesBeforeCaptureStarts() async throws {
        let fixture = SnapshotFixture()
        let desktop = fixture.session()
        let task = desktop.prepareInvocationSnapshot()
        fixture.title = "同一应用的新标签页"
        try await waitUntil { fixture.pending.count == 1 }
        fixture.complete(0)
        let result = await task.value
        XCTAssertEqual(result["context"]?.object?["tree"]?.object?["value"], .string("唤起时的窗口"))
        XCTAssertEqual(result["context"]?.object?["pid"], .number(4242))
        XCTAssertEqual(fixture.capturedContexts.first?["title"], .string("唤起时的窗口"))
        XCTAssertEqual(fixture.capturedContexts.first?["targetId"], .string("target-4242-唤起时的窗口"))
        XCTAssertNotNil(result["capturedAt"])
    }

    func testReopeningDiscardsLateSnapshotAndPreservesTheNewCaptureState() async throws {
        let fixture = SnapshotFixture()
        let desktop = fixture.session()
        let controller = QuickChatController()
        var presented = 0
        controller.prepareInvocation(using: desktop) { presented += 1 }
        let firstConversationID = try XCTUnwrap(controller.conversationID)
        try await waitUntil { fixture.pending.count == 1 }
        fixture.pid = 4343
        fixture.title = "第二次唤起的窗口"
        fixture.image = Data([255, 216, 255, 0])
        controller.prepareInvocation(using: desktop) { presented += 1 }
        XCTAssertNotEqual(controller.conversationID, firstConversationID)
        try await waitUntil { fixture.pending.count == 2 }
        fixture.complete(0)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertTrue(desktop.isPreparingSnapshot)
        XCTAssertEqual(presented, 0)
        XCTAssertNil(controller.desktopSnapshot)
        fixture.complete(1)
        try await waitUntil { presented == 1 }
        XCTAssertEqual(controller.desktopSnapshot?["context"]?.object?["pid"], .number(4343))
        XCTAssertEqual(controller.desktopSnapshot?["context"]?.object?["title"], .string("第二次唤起的窗口"))
        XCTAssertEqual(controller.desktopSnapshot?["image"]?.object?["data"], .string("/9j/AA=="))
        controller.close()
        XCTAssertNil(controller.conversationID)
    }

    func testClosingBeforeCaptureCompletesDoesNotReopenTheInput() async throws {
        let fixture = SnapshotFixture()
        let desktop = fixture.session()
        let controller = QuickChatController()
        var presented = false
        controller.prepareInvocation(using: desktop) { presented = true }
        try await waitUntil { fixture.pending.count == 1 }
        controller.close()
        fixture.complete(0)
        try await waitUntil { !desktop.isPreparingSnapshot }
        for _ in 0..<10 { await Task.yield() }
        XCTAssertFalse(presented)
        XCTAssertNil(controller.desktopSnapshot)
    }

    func testMissingScreenshotPermissionKeepsInvocationTextAndErrorWithoutRetry() async throws {
        let fixture = SnapshotFixture()
        fixture.captureError = .permissionDenied("屏幕录制权限")
        let desktop = fixture.session()
        let controller = QuickChatController()
        var presented = false
        controller.prepareInvocation(using: desktop) { presented = true }
        try await waitUntil { presented }
        let snapshot = try XCTUnwrap(controller.desktopSnapshot)
        fixture.captureError = nil
        fixture.pid = 4343
        desktop.rememberCurrentApplication()
        XCTAssertNil(snapshot["image"])
        XCTAssertTrue(snapshot["screenshotError"]?.string?.contains("屏幕录制权限") == true)
        XCTAssertEqual(snapshot["context"]?.object?["pid"], .number(4242))
        XCTAssertEqual(controller.desktopSnapshot, snapshot)
        XCTAssertTrue(fixture.pending.isEmpty)
        controller.close()
    }

    func testNoInitialApplicationProducesAnExplicitSnapshotFailure() async throws {
        let fixture = SnapshotFixture()
        fixture.pid = nil
        let desktop = fixture.session()
        let snapshot = await desktop.prepareInvocationSnapshot().value
        XCTAssertEqual(snapshot["context"], .object([:]))
        XCTAssertNotNil(snapshot["contextError"])
        XCTAssertNotNil(snapshot["screenshotError"])
        XCTAssertTrue(fixture.pending.isEmpty)
        XCTAssertFalse(desktop.isPreparingSnapshot)
    }
}
