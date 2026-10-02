import Foundation
import Sparkle
import XCTest
@testable import AnotherYouCore

final class UpdateConfigurationTests: XCTestCase {
    private var info: [String: Any] {
        ["AnotherYouUpdatesEnabled": true, "SUFeedURL": "https://updates.example.com/appcast.xml",
         "SUPublicEDKey": Data(repeating: 3, count: 32).base64EncodedString()]
    }

    func testOnlyConfiguredAppBundlesEnableUpdates() throws {
        let configuration = try UpdateConfiguration.resolve(info: info, bundleURL: URL(fileURLWithPath: "/Applications/Test.app")).get()
        XCTAssertEqual(configuration.primaryFeed.absoluteString, "https://updates.example.com/appcast.xml")
        XCTAssertNil(configuration.fallbackFeed)
        XCTAssertThrowsError(try UpdateConfiguration.resolve(info: info, bundleURL: URL(fileURLWithPath: "/tmp/AnotherYou")).get())
        var disabled = info
        disabled["AnotherYouUpdatesEnabled"] = false
        XCTAssertThrowsError(try UpdateConfiguration.resolve(info: disabled, bundleURL: URL(fileURLWithPath: "/Applications/Test.app")).get())
        disabled.removeValue(forKey: "AnotherYouUpdatesEnabled")
        XCTAssertThrowsError(try UpdateConfiguration.resolve(info: disabled, bundleURL: URL(fileURLWithPath: "/Applications/Test.app")).get())
    }

    func testRejectsInvalidFeedsAndSigningKeys() {
        for feed in ["http://updates.example.com/appcast.xml", "file:///tmp/appcast.xml", "https://user:secret@example.com/feed", "https://example.com/feed#fragment", "https://"] {
            var invalid = info
            invalid["SUFeedURL"] = feed
            XCTAssertThrowsError(try UpdateConfiguration.resolve(info: invalid, bundleURL: URL(fileURLWithPath: "/Test.app")).get(), feed)
        }
        for key in ["", "not-a-key", Data(repeating: 1, count: 31).base64EncodedString()] {
            var invalid = info
            invalid["SUPublicEDKey"] = key
            XCTAssertThrowsError(try UpdateConfiguration.resolve(info: invalid, bundleURL: URL(fileURLWithPath: "/Test.app")).get())
        }
        for feed in ["http://fallback.example.com/feed", info["SUFeedURL"] as! String, ""] {
            var invalid = info
            invalid["AnotherYouFallbackFeedURL"] = feed
            XCTAssertThrowsError(try UpdateConfiguration.resolve(info: invalid, bundleURL: URL(fileURLWithPath: "/Test.app")).get())
        }
    }

    func testFallbackFeedRemainsExactlyAsConfigured() throws {
        var configured = info
        configured["AnotherYouFallbackFeedURL"] = "https://mirror.example.com/appcast-arm64.xml"
        let configuration = try UpdateConfiguration.resolve(info: configured, bundleURL: URL(fileURLWithPath: "/Test.app")).get()
        XCTAssertEqual(configuration.fallbackFeed?.absoluteString, "https://mirror.example.com/appcast-arm64.xml")
    }
}

final class UpdateFallbackTests: XCTestCase {
    private let networkError = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)

    func testPrimaryFailureRetriesAtMostOnceAndNextCycleResets() {
        var state = UpdateFallbackState()
        XCTAssertTrue(state.finish(error: networkError, hasFallback: true))
        XCTAssertTrue(state.usingFallback)
        XCTAssertFalse(state.finish(error: networkError, hasFallback: true))
        state.begin()
        XCTAssertFalse(state.usingFallback)
        XCTAssertTrue(state.finish(error: networkError, hasFallback: true))
    }

    func testNoFallbackForSuccessNoUpdateCancellationOrMissingMirror() {
        let errors: [Error?] = [nil, NSError(domain: SUSparkleErrorDomain, code: Int(SUError.noUpdateError.rawValue)),
                               NSError(domain: SUSparkleErrorDomain, code: Int(SUError.installationCanceledError.rawValue)),
                               NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)]
        for error in errors {
            var state = UpdateFallbackState()
            XCTAssertFalse(state.finish(error: error, hasFallback: true))
        }
        var state = UpdateFallbackState()
        XCTAssertFalse(state.finish(error: networkError, hasFallback: false))
        state.didCancel()
        state.didFailDownload()
        XCTAssertFalse(state.finish(error: networkError, hasFallback: true))
    }

    func testOnlyFeedOrDownloadFailureRetriesNotInstallationFailure() {
        var state = UpdateFallbackState()
        state.didLoadAppcast()
        XCTAssertFalse(state.finish(error: networkError, hasFallback: true))
        state.didFailDownload()
        XCTAssertTrue(state.finish(error: networkError, hasFallback: true))
    }
}

@MainActor
private final class TestUpdateDriver: UpdateDriving {
    var checksAutomatically = false
    var downloadsAutomatically = false
    var canCheck = true
    var allowsAutomaticUpdates = true
    var onChange: (() -> Void)?
    var onStatus: ((String?) -> Void)?
    var onInstallReady: ((@escaping () -> Void) -> Bool)?
    var onCycleFinished: (() -> Void)?
    var startCount = 0
    var checkCount = 0
    var startError: Error?
    func start() throws {
        startCount += 1
        if let startError { throw startError }
    }
    func checkForUpdates() { checkCount += 1 }
}

@MainActor
final class UpdateControllerTests: XCTestCase {
    private func withStore(desktop: DesktopSession = DesktopSession(),
                           _ test: (AssistantStore, TestUpdateDriver) async throws -> Void) async throws {
        try await withController { controller, driver, defaults in
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("another-you-update-store-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = AssistantStore(repository: AgentSettingsRepository(dataDirectory: directory), defaults: defaults,
                                       updater: controller, desktop: desktop)
            controller.start()
            controller.setAutomaticChecks(true)
            controller.setAutomaticDownloads(true)
            controller.setAutomaticInstalls(true)
            try await test(store, driver)
            await store.shutdown()
        }
    }

    private func withController(_ test: @MainActor (UpdateController, TestUpdateDriver, UserDefaults) async throws -> Void) async rethrows {
        let name = "another-you-update-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let driver = TestUpdateDriver()
        let controller = UpdateController(driver: driver, defaults: defaults)
        try await test(controller, driver, defaults)
    }

    func testManualChecksWorkWithAutomaticOptionsOffAndStartOnce() async {
        await withController { controller, driver, _ in
            XCTAssertEqual(driver.startCount, 0)
            controller.start()
            controller.start()
            controller.checkForUpdates()
            XCTAssertEqual(driver.startCount, 1)
            XCTAssertEqual(driver.checkCount, 1)
            XCTAssertFalse(driver.checksAutomatically)
            XCTAssertFalse(driver.downloadsAutomatically)
        }
    }

    func testPreferenceDependenciesPersistAndMatchDriver() async {
        await withController { controller, driver, defaults in
            controller.start()
            controller.setAutomaticDownloads(true)
            controller.setAutomaticInstalls(true)
            XCTAssertFalse(driver.downloadsAutomatically)
            XCTAssertFalse(controller.automaticallyInstalls)
            controller.setAutomaticChecks(true)
            controller.setAutomaticDownloads(true)
            controller.setAutomaticInstalls(true)
            XCTAssertTrue(driver.checksAutomatically)
            XCTAssertTrue(driver.downloadsAutomatically)
            let restored = UpdateController(driver: TestUpdateDriver(), defaults: defaults)
            XCTAssertTrue(restored.automaticallyChecks)
            XCTAssertTrue(restored.automaticallyDownloads)
            XCTAssertTrue(restored.automaticallyInstalls)
            controller.setAutomaticChecks(false)
            XCTAssertFalse(driver.checksAutomatically)
            XCTAssertFalse(driver.downloadsAutomatically)
            XCTAssertFalse(controller.automaticallyInstalls)
            XCTAssertEqual(UpdatePreferences(defaults: defaults), UpdatePreferences(checks: false, downloads: false, installs: false))
        }
    }

    func testSparklePreferenceChangesSynchronizeAndCancelPendingInstallation() async {
        await withController { controller, driver, defaults in
            controller.start()
            controller.setAutomaticChecks(true)
            controller.setAutomaticDownloads(true)
            controller.setAutomaticInstalls(true)
            var installs = 0
            XCTAssertTrue(driver.onInstallReady?({ installs += 1 }) == true)
            driver.downloadsAutomatically = false
            driver.onChange?()
            controller.isIdle = { true }
            controller.installWhenIdle()
            XCTAssertEqual(installs, 0)
            XCTAssertFalse(controller.automaticallyDownloads)
            XCTAssertFalse(controller.automaticallyInstalls)
            XCTAssertFalse(UpdatePreferences(defaults: defaults).installs)
        }
    }

    func testDownloadOnlyLeavesInstallationToNormalQuit() async {
        await withController { controller, driver, _ in
            controller.start()
            controller.setAutomaticChecks(true)
            controller.setAutomaticDownloads(true)
            controller.isIdle = { true }
            var installs = 0
            XCTAssertFalse(driver.onInstallReady?({ installs += 1 }) == true)
            controller.installWhenIdle()
            XCTAssertEqual(installs, 0)
            XCTAssertEqual(controller.status, "更新已下载，退出时安装")
        }
    }

    func testAutomaticInstallationWaitsForIdleAndRunsOnce() async {
        await withController { controller, driver, _ in
            controller.start()
            controller.setAutomaticChecks(true)
            controller.setAutomaticDownloads(true)
            controller.setAutomaticInstalls(true)
            var installs = 0
            XCTAssertTrue(driver.onInstallReady?({ installs += 1 }) == true)
            controller.installWhenIdle()
            XCTAssertEqual(installs, 0)
            XCTAssertFalse(controller.isInstalling)
            controller.isIdle = { true }
            controller.installWhenIdle()
            controller.installWhenIdle()
            XCTAssertEqual(installs, 1)
            XCTAssertTrue(controller.isInstalling)
        }
    }

    func testDisablingAutomaticInstallationOrFinishingCycleDropsPendingHandler() async {
        await withController { controller, driver, _ in
            controller.start()
            controller.setAutomaticChecks(true)
            controller.setAutomaticDownloads(true)
            controller.setAutomaticInstalls(true)
            var installs = 0
            XCTAssertTrue(driver.onInstallReady?({ installs += 1 }) == true)
            controller.setAutomaticInstalls(false)
            controller.isIdle = { true }
            controller.installWhenIdle()
            XCTAssertEqual(installs, 0)
            controller.setAutomaticInstalls(true)
            XCTAssertTrue(driver.onInstallReady?({ installs += 1 }) == true)
            driver.onCycleFinished?()
            controller.installWhenIdle()
            XCTAssertEqual(installs, 0)
        }
    }

    func testUnavailableOrFailedUpdaterCannotCheck() async {
        await withController { controller, driver, defaults in
            driver.startError = NSError(domain: "test", code: 1)
            controller.checkForUpdates()
            XCTAssertFalse(controller.canCheck)
            XCTAssertEqual(driver.checkCount, 0)
            XCTAssertEqual(controller.status, "无法启动更新检查")
            let unavailable = UpdateController(driver: nil, defaults: defaults, unavailableMessage: "当前版本不支持自动更新")
            unavailable.checkForUpdates()
            XCTAssertFalse(unavailable.canCheck)
            XCTAssertEqual(unavailable.status, "当前版本不支持自动更新")
        }
    }

    func testUpdateWaitsForBothInputDraftsAndResumesAfterClearingThem() async throws {
        try await withStore { store, driver in
            store.setInputDraft("主窗口未发送内容", for: .conversation)
            store.setInputDraft("快速浮窗未发送内容", for: .quickChat)
            let installed = expectation(description: "all drafts cleared")
            var installs = 0
            XCTAssertTrue(driver.onInstallReady?({ installs += 1; installed.fulfill() }) == true)
            XCTAssertFalse(store.canInstallUpdate)
            store.setInputDraft("", for: .conversation)
            XCTAssertEqual(store.inputDraft(for: .quickChat), "快速浮窗未发送内容")
            XCTAssertFalse(store.canInstallUpdate)
            store.updates.installWhenIdle()
            XCTAssertEqual(installs, 0)
            store.setInputDraft("", for: .quickChat)
            XCTAssertEqual(installs, 0)
            await fulfillment(of: [installed], timeout: 2)
            XCTAssertEqual(installs, 1)
        }
    }

    func testUpdateWaitsForCaptureAndAttachmentThenResumesOnNextMainQueue() async throws {
        let capturing = expectation(description: "capture entered")
        let captured = expectation(description: "capture completed")
        var continuation: CheckedContinuation<DesktopCapture, Error>?
        let desktop = DesktopSession(capture: { _, _ in
            try await withCheckedThrowingContinuation { pending in
                continuation = pending
                capturing.fulfill()
            }
        })
        try await withStore(desktop: desktop) { store, driver in
            desktop.capture(.screen) { captured.fulfill() }
            XCTAssertTrue(desktop.isCapturing)
            XCTAssertFalse(store.canInstallUpdate)
            let installed = expectation(description: "attachment removed")
            var installs = 0
            XCTAssertTrue(driver.onInstallReady?({ installs += 1; installed.fulfill() }) == true)
            await fulfillment(of: [capturing], timeout: 2)
            continuation?.resume(returning: DesktopCapture(imageData: Data([1, 2, 3]), mimeType: "image/png", context: [:], mode: .screen))
            await fulfillment(of: [captured], timeout: 2)
            XCTAssertFalse(desktop.isCapturing)
            XCTAssertEqual(desktop.attachments.count, 1)
            XCTAssertFalse(store.canInstallUpdate)
            XCTAssertEqual(installs, 0)
            desktop.clearAttachments()
            XCTAssertEqual(installs, 0, "objectWillChange must not install synchronously from the old state")
            await fulfillment(of: [installed], timeout: 2)
            XCTAssertEqual(installs, 1)
        }
    }

    func testUpdateWaitsForDesktopOperationAndResumesWhenActivityClears() async throws {
        try await withStore { store, driver in
            let event = AgentEvent(id: "operation", occurredAt: "2026-10-01T10:00:00Z", kind: "desktop.request", source: "agent",
                                   payload: ["requestId": .string("operation"), "arguments": .object(["action": .string("capabilities")])])
            store.desktop.handle(event) { _ in }
            XCTAssertNotNil(store.desktop.activity)
            XCTAssertFalse(store.canInstallUpdate)
            let installed = expectation(description: "desktop completed")
            XCTAssertTrue(driver.onInstallReady?({ installed.fulfill() }) == true)
            await fulfillment(of: [installed], timeout: 2)
            XCTAssertNil(store.desktop.activity)
        }
    }

    func testUpdateInstallationRejectsNewCaptureDraftAndDesktopRequest() async throws {
        var captures = 0
        let desktop = DesktopSession(capture: { _, _ in
            captures += 1
            return DesktopCapture(imageData: Data(), mimeType: "image/png", context: [:], mode: .screen)
        })
        try await withStore(desktop: desktop) { store, driver in
            XCTAssertTrue(driver.onInstallReady?({}) == true)
            store.updates.installWhenIdle()
            XCTAssertTrue(store.updates.isInstalling)
            desktop.capture(.screen)
            XCTAssertFalse(desktop.isCapturing)
            XCTAssertEqual(captures, 0)
            XCTAssertNotNil(desktop.error)
            store.setInputDraft("安装中不能开始输入", for: .conversation)
            XCTAssertTrue(store.inputDraft(for: .conversation).isEmpty)
            let event = AgentEvent(id: "blocked", occurredAt: "2026-10-01T10:00:00Z", kind: "desktop.request", source: "agent",
                                   payload: ["requestId": .string("blocked"), "arguments": .object(["action": .string("capabilities")])])
            var reply: [String: JSONValue]?
            desktop.handle(event) { reply = $0 }
            XCTAssertEqual(reply?["op"], .string("desktopResult"))
            XCTAssertEqual(reply?["requestId"], .string("blocked"))
            XCTAssertNotNil(reply?["error"]?.string)
            XCTAssertNil(desktop.activity)
        }
    }

    func testUpdateGateStillAllowsDesktopCancellationAndManualShutdownWithDrafts() async throws {
        try await withStore { store, _ in
            let request = AgentEvent(id: "operation", occurredAt: "2026-10-01T10:00:00Z", kind: "desktop.request", source: "agent",
                                     payload: ["requestId": .string("operation"), "arguments": .object(["action": .string("capabilities")])])
            store.desktop.handle(request) { _ in }
            XCTAssertNotNil(store.desktop.activity)
            store.desktop.canStartOperation = { false }
            let cancel = AgentEvent(id: "cancel", occurredAt: "2026-10-01T10:00:00Z", kind: "desktop.cancel", source: "agent",
                                    payload: ["requestId": .string("operation")])
            store.desktop.handle(cancel) { _ in XCTFail("cancellation should not be rejected by the start gate") }
            XCTAssertNil(store.desktop.activity)
            store.setInputDraft("未发送草稿", for: .quickChat)
            XCTAssertFalse(store.canInstallUpdate)
            await store.shutdown()
            XCTAssertEqual(store.inputDraft(for: .quickChat), "未发送草稿")
            XCTAssertFalse(store.canInstallUpdate)
        }
    }
}
