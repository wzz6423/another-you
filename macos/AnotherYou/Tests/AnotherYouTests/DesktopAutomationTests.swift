import AppKit
import ApplicationServices
import XCTest
@testable import AnotherYouCore

@MainActor
private final class FakeDesktopAccessibility: DesktopAccessibility {
    var trusted = true
    let app = AXUIElementCreateApplication(1001)
    let field = AXUIElementCreateApplication(1002)
    let secureField = AXUIElementCreateApplication(1003)
    var attributes: [CFHashCode: [String: Any]] = [:]
    var descendants: [CFHashCode: [AXUIElement]] = [:]
    var supportedActions = [kAXPressAction, "AXScrollDown"]
    var settable = true
    var performed: [String] = []
    var written: [String] = []
    var result = AXError.success
    var reads: [(CFHashCode, String)] = []

    init() {
        attributes[CFHash(app)] = [kAXRoleAttribute: kAXApplicationRole, kAXTitleAttribute: "测试应用"]
        attributes[CFHash(field)] = [kAXRoleAttribute: kAXTextFieldRole, kAXTitleAttribute: "草稿", kAXValueAttribute: "用户内容"]
        attributes[CFHash(secureField)] = [kAXRoleAttribute: kAXTextFieldRole, kAXSubroleAttribute: kAXSecureTextFieldSubrole, kAXValueAttribute: "禁止读取的密码"]
        descendants[CFHash(app)] = [field, secureField]
    }

    func root(pid: pid_t) -> AXUIElement { app }
    func attribute(_ name: String, of element: AXUIElement) -> CFTypeRef? {
        reads.append((CFHash(element), name))
        return attributes[CFHash(element)]?[name].map { $0 as CFTypeRef }
    }
    func children(of element: AXUIElement, limit: Int) -> [AXUIElement] { Array((descendants[CFHash(element)] ?? []).prefix(limit)) }
    func actions(of element: AXUIElement) -> [String] { supportedActions }
    func valueIsSettable(_ element: AXUIElement) -> Bool { settable }
    func perform(_ action: String, on element: AXUIElement) -> AXError { performed.append(action); return result }
    func setValue(_ value: String, on element: AXUIElement) -> AXError { written.append(value); return result }
}

@MainActor
final class DesktopAutomationTests: XCTestCase {
    private func automation(_ fake: FakeDesktopAccessibility, exists: Bool = true) -> DesktopAutomation {
        DesktopAutomation(accessibility: fake, application: { pid in
            exists ? DesktopApplicationInfo(pid: pid, name: "测试应用", bundleIdentifier: "test.desktop") : nil
        }, frontmostPID: { 1001 })
    }

    private func fieldID(_ context: [String: JSONValue]) throws -> String {
        try XCTUnwrap(context["tree"]?.object?["children"]?.array?.first?.object?["elementId"]?.string)
    }

    func testContextReadsOnlyRequestedAppAndExcludesSecureValues() throws {
        let fake = FakeDesktopAccessibility()
        let desktop = automation(fake)
        let context = try desktop.context(targetPID: 4242)
        XCTAssertEqual(context["pid"], .number(4242))
        XCTAssertEqual(context["appName"], .string("测试应用"))
        XCTAssertEqual(context["elementCount"], .number(2))
        XCTAssertEqual(context["tree"]?.object?["children"]?.array?.count, 1)
        XCTAssertFalse(fake.reads.contains { $0.0 == CFHash(fake.secureField) && $0.1 == kAXValueAttribute })
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(context), as: UTF8.self).contains("禁止读取的密码"))
    }

    func testContextWithoutPermissionReturnsMetadataWithoutAXReads() throws {
        let fake = FakeDesktopAccessibility()
        fake.trusted = false
        let context = try automation(fake).context()
        XCTAssertEqual(context["accessibilityGranted"], .bool(false))
        XCTAssertNil(context["tree"])
        XCTAssertNotNil(context["warning"])
        XCTAssertTrue(fake.reads.isEmpty)
    }

    func testSnapshotBoundsCycleAndText() throws {
        let fake = FakeDesktopAccessibility()
        fake.descendants[CFHash(fake.field)] = [fake.field]
        fake.attributes[CFHash(fake.field)]?[kAXValueAttribute] = String(repeating: "中", count: 30_000)
        let context = try automation(fake).context()
        XCTAssertEqual(context["truncated"], .bool(true))
        let child = try XCTUnwrap(context["tree"]?.object?["children"]?.array?.first?.object)
        XCTAssertEqual(child["value"]?.string?.count, 1000)
        XCTAssertLessThanOrEqual(DesktopAutomation.number(context["elementCount"]) ?? 1000, 8)
    }

    func testSnapshotHasNodeLimit() throws {
        let fake = FakeDesktopAccessibility()
        fake.descendants[CFHash(fake.app)] = (2000..<2400).map { AXUIElementCreateApplication(pid_t($0)) }
        let context = try automation(fake).context()
        XCTAssertEqual(context["elementCount"], .number(Double(DesktopAutomation.maximumNodes)))
        XCTAssertEqual(context["truncated"], .bool(true))
    }

    func testBackgroundPressSetAndScrollUseOnlyAX() async throws {
        let fake = FakeDesktopAccessibility()
        let desktop = automation(fake)
        let id = try fieldID(desktop.context())
        for action in ["press", "setValue", "scroll"] {
            let result = try await desktop.handle(["action": .string(action), "elementId": .string(id), "value": .string("新内容"), "direction": .string("down")])
            XCTAssertEqual(result["background"], .bool(true))
            XCTAssertEqual(result["performed"], .bool(true))
        }
        XCTAssertEqual(fake.performed, [kAXPressAction, "AXScrollDown"])
        XCTAssertEqual(fake.written, ["新内容"])
    }

    func testUnsupportedBackgroundActionNeverFallsBack() async throws {
        let fake = FakeDesktopAccessibility()
        fake.supportedActions = []
        let desktop = automation(fake)
        let id = try fieldID(desktop.context())
        do {
            _ = try await desktop.handle(["action": .string("press"), "elementId": .string(id)])
            XCTFail("应拒绝没有 AX 动作的元素")
        } catch let error as DesktopAutomationError {
            guard case .unsupported = error else { return XCTFail("\(error)") }
        }
        XCTAssertTrue(fake.performed.isEmpty)
    }

    func testStaleAndCrossAppElementsAreRejected() async throws {
        let fake = FakeDesktopAccessibility()
        let desktop = automation(fake)
        let oldID = try fieldID(desktop.context())
        let newID = try fieldID(desktop.context())
        XCTAssertNotEqual(oldID, newID)
        for arguments: [String: JSONValue] in [
            ["action": .string("press"), "elementId": .string(oldID)],
            ["action": .string("press"), "elementId": .string(newID), "pid": .number(2002)]
        ] {
            do { _ = try await desktop.handle(arguments); XCTFail("应拒绝过期或跨应用元素") }
            catch is DesktopAutomationError { }
        }
        XCTAssertTrue(fake.performed.isEmpty)
    }

    func testPermissionRevocationAndNewSecureStatePreventWrites() async throws {
        let fake = FakeDesktopAccessibility()
        let desktop = automation(fake)
        let id = try fieldID(desktop.context())
        fake.trusted = false
        do { _ = try await desktop.handle(["action": .string("press"), "elementId": .string(id)]); XCTFail("应拒绝权限撤销") }
        catch let error as DesktopAutomationError { XCTAssertEqual(error, .permissionDenied("辅助功能权限")) }
        fake.trusted = true
        fake.attributes[CFHash(fake.field)]?[kAXSubroleAttribute] = kAXSecureTextFieldSubrole
        do { _ = try await desktop.handle(["action": .string("setValue"), "elementId": .string(id), "value": .string("秘密")]); XCTFail("应重新检查密码框") }
        catch let error as DesktopAutomationError {
            guard case .unsupported = error else { return XCTFail("\(error)") }
        }
        XCTAssertTrue(fake.written.isEmpty)
        XCTAssertTrue(fake.performed.isEmpty)
    }

    func testForegroundRequiresExplicitOptInBeforeOSAccess() async throws {
        let fake = FakeDesktopAccessibility()
        let desktop = automation(fake)
        for action in ["click", "type", "key"] {
            do { _ = try await desktop.handle(["action": .string(action)]); XCTFail("应拒绝隐式前台输入") }
            catch let error as DesktopAutomationError {
                guard case .unsupported = error else { return XCTFail("\(error)") }
            }
        }
        XCTAssertTrue(fake.reads.isEmpty)
    }

    func testInteractiveRegionRequiresForegroundOptIn() async throws {
        let desktop = automation(FakeDesktopAccessibility())
        do {
            _ = try await desktop.handle(["action": .string("screenshot"), "mode": .string("region")])
            XCTFail("后台截图不应触发交互选区")
        } catch let error as DesktopAutomationError {
            guard case .unsupported = error else { return XCTFail("\(error)") }
        }
    }

    func testAXFailuresAreReported() async throws {
        let fake = FakeDesktopAccessibility()
        let desktop = automation(fake)
        let id = try fieldID(desktop.context())
        for (result, expected) in [(AXError.invalidUIElement, DesktopAutomationError.staleElement), (.cannotComplete, .timedOut)] {
            fake.result = result
            do { _ = try await desktop.handle(["action": .string("press"), "elementId": .string(id)]); XCTFail("应报告 AX 错误") }
            catch let error as DesktopAutomationError { XCTAssertEqual(error, expected) }
        }
    }

    func testScrollCountAndReadonlyValueAreValidatedBeforeWriting() async throws {
        let fake = FakeDesktopAccessibility()
        let desktop = automation(fake)
        let id = try fieldID(desktop.context())
        _ = try await desktop.handle(["action": .string("scroll"), "elementId": .string(id), "direction": .string("down"), "amount": .number(3)])
        XCTAssertEqual(fake.performed, ["AXScrollDown", "AXScrollDown", "AXScrollDown"])
        for value in [JSONValue.number(0), .number(11), .number(1.5), .number(.infinity)] {
            XCTAssertThrowsError(try DesktopAutomation.scrollAmount(value))
        }
        fake.settable = false
        do { _ = try await desktop.handle(["action": .string("setValue"), "elementId": .string(id), "value": .string("草稿")]); XCTFail("只读字段应拒绝写入") }
        catch is DesktopAutomationError { }
        XCTAssertTrue(fake.written.isEmpty)
    }

    func testCaptureCallbackIgnoresDuplicateCompletionAndTimesOut() async throws {
        let desktop = automation(FakeDesktopAccessibility())
        let value: Int = try await desktop.captureOperation { complete in
            complete(.success(7))
            complete(.success(8))
        }
        XCTAssertEqual(value, 7)
        do {
            let _: Int = try await desktop.captureOperation(timeout: 0.02) { _ in }
            XCTFail("没有系统回调时应超时")
        } catch let error as DesktopAutomationError { XCTAssertEqual(error, .timedOut) }
    }

    func testCaptureCancellationDoesNotWaitForSystemCallback() async throws {
        let desktop = automation(FakeDesktopAccessibility())
        var lateCompletion: (@Sendable (Result<Int, any Error>) -> Void)?
        let task = Task { @MainActor in
            try await desktop.captureOperation { complete in lateCompletion = complete }
        }
        await Task.yield()
        task.cancel()
        do { _ = try await task.value; XCTFail("取消应立即返回") }
        catch is CancellationError { }
        lateCompletion?(.success(1))
    }

    func testInvalidPIDRegionAndInputAreRejected() throws {
        for value in [JSONValue.number(-1), .number(.infinity), .number(1.5), .number(Double(Int32.max) + 1), .string("1001")] {
            XCTAssertThrowsError(try DesktopAutomation.pid(value))
        }
        XCTAssertEqual(try DesktopAutomation.pid(.number(1001)), 1001)
        XCTAssertNil(try DesktopAutomation.pid(nil))
        XCTAssertThrowsError(try DesktopAutomation.region(.object(["x": .number(0), "y": .number(0), "width": .number(-1), "height": .number(10)])))
        XCTAssertThrowsError(try DesktopAutomation.region(.object(["x": .number(.nan), "y": .number(0), "width": .number(10), "height": .number(10)])))
        XCTAssertEqual(try DesktopAutomation.region(.object(["x": .number(-100), "y": .number(0), "width": .number(50), "height": .number(10)])), CGRect(x: -100, y: 0, width: 50, height: 10))
        XCTAssertThrowsError(try DesktopAutomation.input(.string(String(repeating: "🙂", count: 4001))))
        XCTAssertEqual(try DesktopAutomation.input(.string("")), "")
    }

    func testUnicodeChunksPreserveSurrogatePairsAndOrder() {
        let text = String(repeating: "a", count: 19) + "🙂你好" + String(repeating: "b", count: 37)
        let chunks = DesktopAutomation.unicodeChunks(text)
        XCTAssertEqual(chunks.flatMap { $0 }, Array(text.utf16))
        XCTAssertTrue(chunks.allSatisfy { $0.count <= 20 })
        XCTAssertTrue(chunks.allSatisfy { $0.last.map { !(0xD800...0xDBFF).contains($0) } ?? true })
        XCTAssertTrue(DesktopAutomation.unicodeChunks("").isEmpty)
    }

    func testImageCompressionBoundsPayloadAndDimensions() throws {
        let width = 3200, height = 2200
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(NSColor.systemBlue.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let data = try DesktopAutomation.compress(image)
        XCTAssertLessThanOrEqual(data.count, DesktopAutomation.maximumImageBytes)
        let decoded = try XCTUnwrap(NSBitmapImageRep(data: data))
        XCTAssertLessThanOrEqual(max(decoded.pixelsWide, decoded.pixelsHigh), 1600)
        XCTAssertEqual(decoded.pixelsWide, 1600)
        let capture = DesktopCapture(imageData: data, mimeType: "image/jpeg", context: ["pid": .number(1001)], mode: .window)
        XCTAssertEqual(capture.json["mode"], .string("window"))
        XCTAssertEqual(capture.json["image"]?.object?["mimeType"], .string("image/jpeg"))
        XCTAssertLessThanOrEqual(capture.json["image"]?.object?["data"]?.string?.utf8.count ?? Int.max, 600_000)
    }

    func testTerminatedApplicationIsUnavailable() {
        XCTAssertThrowsError(try automation(FakeDesktopAccessibility(), exists: false).context())
    }
}
