import AppKit
import ApplicationServices
import Foundation
@preconcurrency import ScreenCaptureKit

public enum DesktopCaptureMode: String, CaseIterable, Sendable {
    case screen, window, region
}

public struct DesktopCapture: Sendable, Equatable {
    public let imageData: Data
    public let mimeType: String
    public let context: [String: JSONValue]
    public let mode: DesktopCaptureMode

    public var json: [String: JSONValue] {
        ["image": .object(["data": .string(imageData.base64EncodedString()), "mimeType": .string(mimeType)]),
         "context": .object(context), "mode": .string(mode.rawValue)]
    }
}

public enum DesktopAutomationError: LocalizedError, Equatable {
    case invalidArguments(String), permissionDenied(String), unavailable(String), unsupported(String)
    case staleElement, cancelled, timedOut

    public var errorDescription: String? {
        switch self {
        case .invalidArguments(let detail): "桌面操作参数无效：\(detail)"
        case .permissionDenied(let permission): "需要在系统设置中允许\(permission)。"
        case .unavailable(let detail): "桌面操作不可用：\(detail)"
        case .unsupported(let detail): "应用不支持此操作：\(detail)"
        case .staleElement: "界面元素已过期，请重新获取应用上下文。"
        case .cancelled: "已取消截图。"
        case .timedOut: "应用响应超时，请重试。"
        }
    }
}

@MainActor
protocol DesktopAccessibility {
    var trusted: Bool { get }
    func root(pid: pid_t) -> AXUIElement
    func attribute(_ name: String, of element: AXUIElement) -> CFTypeRef?
    func children(of element: AXUIElement, limit: Int) -> [AXUIElement]
    func actions(of element: AXUIElement) -> [String]
    func valueIsSettable(_ element: AXUIElement) -> Bool
    func perform(_ action: String, on element: AXUIElement) -> AXError
    func setValue(_ value: String, on element: AXUIElement) -> AXError
}

@MainActor
private struct SystemDesktopAccessibility: DesktopAccessibility {
    var trusted: Bool { AXIsProcessTrusted() }

    func root(pid: pid_t) -> AXUIElement {
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, 0.15)
        return element
    }

    func attribute(_ name: String, of element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    func children(of element: AXUIElement, limit: Int) -> [AXUIElement] {
        guard limit > 0 else { return [] }
        var value: CFArray?
        guard AXUIElementCopyAttributeValues(element, kAXChildrenAttribute as CFString, 0, limit, &value) == .success else { return [] }
        let children = value as? [AXUIElement] ?? []
        for child in children { AXUIElementSetMessagingTimeout(child, 0.15) }
        return children
    }

    func actions(of element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success else { return [] }
        return names as? [String] ?? []
    }

    func valueIsSettable(_ element: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success && settable.boolValue
    }

    func perform(_ action: String, on element: AXUIElement) -> AXError {
        AXUIElementPerformAction(element, action as CFString)
    }

    func setValue(_ value: String, on element: AXUIElement) -> AXError {
        AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, value as CFString)
    }
}

struct DesktopApplicationInfo {
    let pid: pid_t
    let name: String
    let bundleIdentifier: String?
}

// ScreenCaptureKit 的回调结果只单向交给主线程，锁保证超时、取消和系统回调只完成一次。
private struct DesktopCaptureTransfer<Value>: @unchecked Sendable {
    let value: Value
}

private final class DesktopCaptureLatch<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<DesktopCaptureTransfer<Value>, any Error>?
    private var resolution: Result<DesktopCaptureTransfer<Value>, any Error>?

    func install(_ continuation: CheckedContinuation<DesktopCaptureTransfer<Value>, any Error>) {
        lock.lock()
        if let resolution {
            lock.unlock()
            continuation.resume(with: resolution)
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }

    func finish(_ result: Result<Value, any Error>) {
        lock.lock()
        guard resolution == nil else { lock.unlock(); return }
        let transferred = result.map { DesktopCaptureTransfer(value: $0) }
        resolution = transferred
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: transferred)
    }
}

@MainActor
public final class DesktopAutomation {
    private let accessibility: any DesktopAccessibility
    private let application: (pid_t) -> DesktopApplicationInfo?
    private let frontmostPID: () -> pid_t?
    private var elements: [String: AXUIElement] = [:]
    private var snapshotPID: pid_t?
    private var snapshotDate = Date.distantPast
    private var captureInProgress = false
    static let maximumImageBytes = 450_000
    static let maximumInputLength = 8_000
    static let maximumNodes = 120

    public static var frontmostApplicationPID: pid_t? { NSWorkspace.shared.frontmostApplication?.processIdentifier }

    public convenience init() {
        self.init(accessibility: SystemDesktopAccessibility(), application: { pid in
            guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else { return nil }
            return DesktopApplicationInfo(pid: pid, name: app.localizedName ?? "未知应用", bundleIdentifier: app.bundleIdentifier)
        }, frontmostPID: { Self.frontmostApplicationPID })
    }

    init(accessibility: any DesktopAccessibility, application: @escaping (pid_t) -> DesktopApplicationInfo?, frontmostPID: @escaping () -> pid_t?) {
        self.accessibility = accessibility
        self.application = application
        self.frontmostPID = frontmostPID
    }

    public func handle(_ arguments: [String: JSONValue]) async throws -> [String: JSONValue] {
        try Task.checkCancellation()
        let action = arguments["action"]?.string ?? "capabilities"
        let background = arguments["background"]?.bool ?? true
        switch action {
        case "capabilities": return capabilities
        case "requestPermissions":
            switch arguments["permission"]?.string {
            case "accessibility":
                let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
                _ = AXIsProcessTrustedWithOptions(options)
            case "screenRecording": _ = CGRequestScreenCaptureAccess()
            default: throw DesktopAutomationError.invalidArguments("permission 必须为 accessibility 或 screenRecording")
            }
            return capabilities
        case "context", "snapshot": return try context(targetPID: try Self.pid(arguments["pid"]))
        case "screenshot":
            guard let mode = DesktopCaptureMode(rawValue: arguments["mode"]?.string ?? "window") else {
                throw DesktopAutomationError.invalidArguments("mode 必须为 screen、window 或 region")
            }
            let region = try Self.region(arguments["rect"])
            if mode == .region && region == nil && background {
                throw DesktopAutomationError.unsupported("后台截图需要 rect；交互选区请明确设置 background=false")
            }
            return try await capture(mode: mode, targetPID: Self.pid(arguments["pid"]), includeContext: arguments["includeContext"]?.bool ?? true, region: region).json
        case "press", "setValue", "scroll":
            guard accessibility.trusted else { throw DesktopAutomationError.permissionDenied("辅助功能权限") }
            let element = try resolveElement(arguments)
            let result: AXError
            if action == "setValue" {
                let value = try Self.input(arguments["value"])
                guard accessibility.valueIsSettable(element) else { throw DesktopAutomationError.unsupported("此元素不允许直接修改值") }
                result = accessibility.setValue(value, on: element)
            } else {
                let requested: String
                if action == "press" { requested = kAXPressAction }
                else {
                    let directions = ["up": "AXScrollUp", "down": "AXScrollDown", "left": "AXScrollLeft", "right": "AXScrollRight"]
                    guard let direction = arguments["direction"]?.string, let name = directions[direction] else {
                        throw DesktopAutomationError.invalidArguments("direction 必须为 up、down、left 或 right")
                    }
                    requested = name
                }
                guard accessibility.actions(of: element).contains(requested) else {
                    throw DesktopAutomationError.unsupported("此元素没有 \(requested) 动作；不会切换到前台模拟输入")
                }
                let count = action == "scroll" ? try Self.scrollAmount(arguments["amount"]) : 1
                for _ in 1..<count {
                    try Task.checkCancellation()
                    try checkAX(accessibility.perform(requested, on: element))
                }
                result = accessibility.perform(requested, on: element)
            }
            try checkAX(result)
            return ["performed": .bool(true), "background": .bool(true), "action": .string(action)]
        case "click", "type", "key":
            guard !background else { throw DesktopAutomationError.unsupported("\(action) 需要明确设置 background=false；后台请使用 press 或 setValue") }
            guard accessibility.trusted else { throw DesktopAutomationError.permissionDenied("辅助功能权限") }
            guard let pid = try Self.pid(arguments["pid"]) else { throw DesktopAutomationError.invalidArguments("前台输入必须指定 pid") }
            return try await foreground(action: action, pid: pid, arguments: arguments)
        default: throw DesktopAutomationError.invalidArguments("未知 action：\(action)")
        }
    }

    public var capabilities: [String: JSONValue] {
        ["platform": .string("macOS"), "accessibilityGranted": .bool(accessibility.trusted),
         "screenRecordingGranted": .bool(CGPreflightScreenCaptureAccess()),
         "backgroundActions": .array(["context", "screenshot", "press", "setValue", "scroll"].map(JSONValue.string)),
         "foregroundActions": .array(["click", "type", "key"].map(JSONValue.string)),
         "captureModes": .array(DesktopCaptureMode.allCases.map { .string($0.rawValue) }),
         "limitations": .string("后台操作取决于目标应用提供的辅助功能动作，不支持的控件会报错；交互选区和前台输入会显示在屏幕上。")]
    }

    public func context(targetPID: pid_t? = nil) throws -> [String: JSONValue] {
        guard let pid = targetPID ?? frontmostPID(), let app = application(pid) else {
            throw DesktopAutomationError.unavailable("目标应用已经退出或没有前台应用")
        }
        elements.removeAll()
        snapshotPID = pid
        snapshotDate = Date()
        var result: [String: JSONValue] = ["pid": .number(Double(pid)), "appName": .string(app.name),
            "bundleId": app.bundleIdentifier.map(JSONValue.string) ?? .null, "accessibilityGranted": .bool(accessibility.trusted)]
        guard accessibility.trusted else {
            result["warning"] = .string("未授予辅助功能权限，只包含应用信息。")
            return result
        }
        let root = accessibility.root(pid: pid)
        if let focused = accessibility.attribute(kAXFocusedWindowAttribute, of: root), CFGetTypeID(focused) == AXUIElementGetTypeID() {
            let window = unsafeDowncast(focused, to: AXUIElement.self)
            if let title = accessibility.attribute(kAXTitleAttribute, of: window) as? String {
                result["title"] = .string(String(title.prefix(1000)))
            }
        }
        let snapshot = UUID().uuidString
        var remainingCharacters = 20_000
        var truncated = false
        let deadline = Date().addingTimeInterval(2)
        if let tree = snapshotElement(root, snapshot: snapshot, depth: 0, remainingCharacters: &remainingCharacters, truncated: &truncated, deadline: deadline) {
            result["tree"] = .object(tree)
        }
        result["snapshotId"] = .string(snapshot)
        result["truncated"] = .bool(truncated)
        result["elementCount"] = .number(Double(elements.count))
        return result
    }

    private func snapshotElement(_ element: AXUIElement, snapshot: String, depth: Int, remainingCharacters: inout Int, truncated: inout Bool, deadline: Date) -> [String: JSONValue]? {
        guard elements.count < Self.maximumNodes, depth < 8, remainingCharacters > 0, Date() < deadline, !Task.isCancelled else {
            truncated = true
            return nil
        }
        guard !isSecure(element) else { return nil }
        let id = "\(snapshot):\(elements.count)"
        elements[id] = element
        var node: [String: JSONValue] = ["elementId": .string(id)]
        for (key, attribute) in [("role", kAXRoleAttribute), ("subrole", kAXSubroleAttribute), ("title", kAXTitleAttribute), ("description", kAXDescriptionAttribute), ("value", kAXValueAttribute)] {
            guard remainingCharacters > 0, Date() < deadline else { truncated = true; break }
            if let text = accessibility.attribute(attribute, of: element) as? String {
                let bounded = String(text.prefix(min(1000, remainingCharacters)))
                remainingCharacters -= bounded.count
                if bounded.count < text.count { truncated = true }
                node[key] = .string(bounded)
            }
        }
        guard Date() < deadline else { truncated = true; return node }
        node["actions"] = .array(accessibility.actions(of: element).prefix(12).map(JSONValue.string))
        node["valueSettable"] = .bool(accessibility.valueIsSettable(element))
        let capacity = Self.maximumNodes - elements.count
        let children = accessibility.children(of: element, limit: min(capacity + 1, Self.maximumNodes))
        var output: [JSONValue] = []
        for child in children {
            if let value = snapshotElement(child, snapshot: snapshot, depth: depth + 1, remainingCharacters: &remainingCharacters, truncated: &truncated, deadline: deadline) {
                output.append(.object(value))
            }
            if Date() >= deadline || elements.count >= Self.maximumNodes || remainingCharacters <= 0 { truncated = true; break }
        }
        if !output.isEmpty { node["children"] = .array(output) }
        return node
    }

    private func isSecure(_ element: AXUIElement) -> Bool {
        let subrole = accessibility.attribute(kAXSubroleAttribute, of: element) as? String
        return subrole == kAXSecureTextFieldSubrole || (accessibility.attribute("AXProtectedContent", of: element) as? Bool == true)
    }

    private func resolveElement(_ arguments: [String: JSONValue]) throws -> AXUIElement {
        guard let id = arguments["elementId"]?.string, let element = elements[id],
              let pid = snapshotPID, Date().timeIntervalSince(snapshotDate) < 60,
              application(pid) != nil else { throw DesktopAutomationError.staleElement }
        if let requestedPID = try Self.pid(arguments["pid"]), requestedPID != pid {
            throw DesktopAutomationError.invalidArguments("elementId 不属于指定 pid")
        }
        guard !isSecure(element) else { throw DesktopAutomationError.unsupported("不操作密码或受保护的输入框") }
        return element
    }

    private func checkAX(_ error: AXError) throws {
        guard error == .success else {
            if error == .invalidUIElement { throw DesktopAutomationError.staleElement }
            if error == .cannotComplete { throw DesktopAutomationError.timedOut }
            throw DesktopAutomationError.unsupported("辅助功能返回错误 \(error.rawValue)")
        }
    }

    public func capture(mode: DesktopCaptureMode = .region, targetPID: pid_t? = nil, includeContext: Bool = true, region: CGRect? = nil) async throws -> DesktopCapture {
        guard !captureInProgress else { throw DesktopAutomationError.unavailable("已有截图正在进行") }
        guard CGPreflightScreenCaptureAccess() else { throw DesktopAutomationError.permissionDenied("屏幕录制权限") }
        let pid = targetPID ?? frontmostPID()
        guard let pid, application(pid) != nil else { throw DesktopAutomationError.unavailable("目标应用已经退出或没有前台应用") }
        captureInProgress = true
        defer { captureInProgress = false }
        try Task.checkCancellation()
        var appContext = includeContext ? try context(targetPID: pid) : ["pid": .number(Double(pid))]
        let image: CGImage
        if mode == .region && region == nil {
            image = try await interactiveRegion()
        } else {
            image = try await captureImage(mode: mode, pid: pid, region: region)
        }
        try Task.checkCancellation()
        let data = try Self.compress(image)
        appContext["capturedAt"] = .string(ISO8601DateFormatter().string(from: Date()))
        appContext["coordinateSpace"] = .string("global-top-left-points")
        return DesktopCapture(imageData: data, mimeType: "image/jpeg", context: appContext, mode: mode)
    }

    private func captureImage(mode: DesktopCaptureMode, pid: pid_t, region: CGRect?) async throws -> CGImage {
        let content: SCShareableContent = try await captureOperation { complete in
            SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: false) { content, error in
                if let content { complete(.success(content)) }
                else { complete(.failure(error ?? DesktopAutomationError.unavailable("无法枚举屏幕窗口"))) }
            }
        }
        try Task.checkCancellation()
        guard application(pid) != nil else { throw DesktopAutomationError.unavailable("目标应用已经退出") }
        let candidates = content.windows.filter { $0.owningApplication?.processID == pid && $0.windowLayer == 0 && $0.frame.width > 30 && $0.frame.height > 30 }
        let orderedIDs = (CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? [])
            .compactMap { $0[kCGWindowNumber as String] as? CGWindowID }
        let window = candidates.min { (orderedIDs.firstIndex(of: $0.windowID) ?? Int.max) < (orderedIDs.firstIndex(of: $1.windowID) ?? Int.max) }
        let configuration = SCStreamConfiguration()
        configuration.showsCursor = false
        configuration.capturesAudio = false
        let filter: SCContentFilter
        let size: CGSize
        if mode == .window {
            guard let window else { throw DesktopAutomationError.unavailable("目标应用没有可捕获的窗口") }
            filter = SCContentFilter(desktopIndependentWindow: window)
            size = window.frame.size
        } else {
            let target = region ?? window?.frame
            let display = target.flatMap { target in content.displays.max { $0.frame.intersection(target).area < $1.frame.intersection(target).area } }
                ?? content.displays.first { $0.displayID == CGMainDisplayID() } ?? content.displays.first
            guard let display else { throw DesktopAutomationError.unavailable("没有可捕获的屏幕") }
            filter = SCContentFilter(display: display, excludingWindows: [])
            if let region, mode == .region {
                guard Self.validRegion(region), display.frame.contains(region) else {
                    throw DesktopAutomationError.invalidArguments("rect 必须完整位于同一块屏幕内，坐标采用全局左上原点")
                }
                configuration.sourceRect = CGRect(x: region.minX - display.frame.minX, y: region.minY - display.frame.minY, width: region.width, height: region.height)
                size = region.size
            } else { size = display.frame.size }
        }
        let scale = min(1, 1600 / max(size.width, size.height))
        configuration.width = max(1, Int(size.width * scale))
        configuration.height = max(1, Int(size.height * scale))
        return try await captureOperation { complete in
            SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) { image, error in
                if let image { complete(.success(image)) }
                else { complete(.failure(error ?? DesktopAutomationError.unavailable("无法获取截图"))) }
            }
        }
    }

    func captureOperation<Value>(timeout: TimeInterval = 10, _ start: (@escaping @Sendable (Result<Value, any Error>) -> Void) -> Void) async throws -> Value {
        try Task.checkCancellation()
        let latch = DesktopCaptureLatch<Value>()
        let result: DesktopCaptureTransfer<Value> = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                latch.install(continuation)
                start { latch.finish($0) }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    latch.finish(.failure(DesktopAutomationError.timedOut))
                }
            }
        } onCancel: { latch.finish(.failure(CancellationError())) }
        return result.value
    }

    private func interactiveRegion() async throws -> CGImage {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("another-you-capture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("region.png")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-i", "-s", "-x", "-t", "png", path.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = Date().addingTimeInterval(120)
        do {
            while process.isRunning {
                try Task.checkCancellation()
                guard Date() < deadline else { throw DesktopAutomationError.timedOut }
                try await Task.sleep(for: .milliseconds(50))
            }
        } catch {
            if process.isRunning { process.terminate() }
            // 等待子进程退出后再删除目录，避免取消时留下晚写入的截图。
            let stopped = Task.detached {
                for _ in 0..<40 {
                    if !process.isRunning { return }
                    try? await Task.sleep(for: .milliseconds(25))
                }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
            }
            await stopped.value
            throw error
        }
        guard process.terminationStatus == 0, let data = try? Data(contentsOf: path),
              let bitmap = NSBitmapImageRep(data: data), let image = bitmap.cgImage else {
            throw DesktopAutomationError.cancelled
        }
        return image
    }

    static func compress(_ image: CGImage) throws -> Data {
        var maxDimension: CGFloat = 1600
        for _ in 0..<5 {
            let scale = min(1, maxDimension / CGFloat(max(image.width, image.height)))
            let width = max(1, Int(CGFloat(image.width) * scale))
            let height = max(1, Int(CGFloat(image.height) * scale))
            guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
                throw DesktopAutomationError.unavailable("无法创建截图缩略图")
            }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            guard let resized = context.makeImage() else { throw DesktopAutomationError.unavailable("截图为空") }
            let bitmap = NSBitmapImageRep(cgImage: resized)
            for quality in [0.8, 0.6, 0.4] {
                if let data = bitmap.representation(using: .jpeg, properties: [.compressionFactor: quality]), data.count <= maximumImageBytes { return data }
            }
            maxDimension *= 0.7
        }
        throw DesktopAutomationError.unavailable("截图超过传输大小限制")
    }

    private func foreground(action: String, pid: pid_t, arguments: [String: JSONValue]) async throws -> [String: JSONValue] {
        // 先验证输入，避免参数错误也把用户切走。
        let input = action == "type" ? try Self.input(arguments["text"]) : nil
        let key = action == "key" ? try Self.key(arguments["key"]?.string) : nil
        let flags = try Self.modifiers(arguments["modifiers"])
        let point: CGPoint?
        if action == "click" {
            guard let x = Self.number(arguments["x"]), let y = Self.number(arguments["y"]), x.isFinite, y.isFinite else {
                throw DesktopAutomationError.invalidArguments("click 需要有限数值 x 和 y")
            }
            point = CGPoint(x: x, y: y)
            guard NSScreen.screens.contains(where: { screen in
                guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return false }
                return CGDisplayBounds(id).contains(point!)
            }) else { throw DesktopAutomationError.invalidArguments("点击坐标不在屏幕内") }
        } else { point = nil }
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else { throw DesktopAutomationError.unavailable("目标应用已经退出") }
        guard app.activate(options: []) else { throw DesktopAutomationError.unavailable("无法激活目标应用") }
        for _ in 0..<20 {
            try Task.checkCancellation()
            if Self.frontmostApplicationPID == pid { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        guard Self.frontmostApplicationPID == pid else { throw DesktopAutomationError.unavailable("目标应用没有进入前台") }
        if point == nil, let focused = accessibility.attribute(kAXFocusedUIElementAttribute, of: accessibility.root(pid: pid)),
           CFGetTypeID(focused) == AXUIElementGetTypeID(), isSecure(unsafeDowncast(focused, to: AXUIElement.self)) {
            throw DesktopAutomationError.unsupported("不操作密码或受保护的输入框")
        }
        if let point {
            var hit: AXUIElement?
            let system = AXUIElementCreateSystemWide()
            guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit) == .success, let hit else {
                throw DesktopAutomationError.unavailable("无法验证点击目标")
            }
            var hitPID: pid_t = 0
            guard AXUIElementGetPid(hit, &hitPID) == .success, hitPID == pid else { throw DesktopAutomationError.invalidArguments("点击坐标不属于目标应用") }
            for type in [CGEventType.leftMouseDown, .leftMouseUp] {
                guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left) else { throw DesktopAutomationError.unavailable("无法创建鼠标事件") }
                event.flags = flags
                event.post(tap: .cghidEventTap)
            }
        } else if let input {
            for chunk in Self.unicodeChunks(input) {
                guard Self.frontmostApplicationPID == pid else { throw DesktopAutomationError.unavailable("用户已切换应用，停止输入") }
                for down in [true, false] {
                    guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down) else { throw DesktopAutomationError.unavailable("无法创建键盘事件") }
                    chunk.withUnsafeBufferPointer { event.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: $0.baseAddress!) }
                    event.post(tap: .cghidEventTap)
                }
            }
        } else if let key {
            for down in [true, false] {
                guard let event = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: down) else { throw DesktopAutomationError.unavailable("无法创建键盘事件") }
                event.flags = flags
                event.post(tap: .cghidEventTap)
            }
        }
        return ["performed": .bool(true), "background": .bool(false), "action": .string(action), "pid": .number(Double(pid))]
    }

    static func number(_ value: JSONValue?) -> Double? {
        if case .number(let number) = value { return number }
        return nil
    }

    static func pid(_ value: JSONValue?) throws -> pid_t? {
        guard let value else { return nil }
        guard let number = number(value), number.isFinite, number > 0, number <= Double(Int32.max), number.rounded() == number else {
            throw DesktopAutomationError.invalidArguments("pid 必须为有效进程编号")
        }
        return pid_t(number)
    }

    static func input(_ value: JSONValue?) throws -> String {
        guard let text = value?.string, text.utf16.count <= maximumInputLength else {
            throw DesktopAutomationError.invalidArguments("输入必须为最多 \(maximumInputLength) 个 UTF-16 字符的文本")
        }
        return text
    }

    static func scrollAmount(_ value: JSONValue?) throws -> Int {
        guard let value else { return 1 }
        guard let amount = number(value), amount.isFinite, amount.rounded() == amount, (1...10).contains(amount) else {
            throw DesktopAutomationError.invalidArguments("amount 必须为 1 到 10 的整数，表示辅助功能滚动次数")
        }
        return Int(amount)
    }

    static func validRegion(_ rect: CGRect) -> Bool {
        [rect.origin.x, rect.origin.y, rect.size.width, rect.size.height].allSatisfy(\.isFinite) && rect.size.width >= 1 && rect.size.height >= 1
    }

    static func region(_ value: JSONValue?) throws -> CGRect? {
        guard let value else { return nil }
        guard let object = value.object, let x = number(object["x"]), let y = number(object["y"]),
              let width = number(object["width"]), let height = number(object["height"]) else {
            throw DesktopAutomationError.invalidArguments("rect 需要 x、y、width 和 height")
        }
        let rect = CGRect(x: x, y: y, width: width, height: height)
        guard validRegion(rect) else { throw DesktopAutomationError.invalidArguments("rect 坐标必须有限，宽高至少为 1") }
        return rect
    }

    static func modifiers(_ value: JSONValue?) throws -> CGEventFlags {
        guard let value else { return [] }
        guard let values = value.array else { throw DesktopAutomationError.invalidArguments("modifiers 必须为数组") }
        var flags: CGEventFlags = []
        for entry in values {
            switch entry.string {
            case "command", "cmd": flags.insert(.maskCommand)
            case "option", "alt": flags.insert(.maskAlternate)
            case "control", "ctrl": flags.insert(.maskControl)
            case "shift": flags.insert(.maskShift)
            default: throw DesktopAutomationError.invalidArguments("未知修饰键")
            }
        }
        return flags
    }

    static func key(_ value: String?) throws -> CGKeyCode {
        let keys: [String: CGKeyCode] = ["return": 36, "enter": 36, "tab": 48, "space": 49, "delete": 51,
            "escape": 53, "forwarddelete": 117, "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
            "left": 123, "right": 124, "down": 125, "up": 126,
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
            "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19,
            "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26, "8": 28, "0": 29,
            "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46]
        guard let value, let key = keys[value.lowercased()] else { throw DesktopAutomationError.invalidArguments("不支持的 key") }
        return key
    }

    static func unicodeChunks(_ text: String) -> [[UniChar]] {
        var chunks: [[UniChar]] = []
        var current: [UniChar] = []
        for scalar in text.unicodeScalars {
            let units = Array(String(scalar).utf16)
            if current.count + units.count > 20 { chunks.append(current); current = [] }
            current.append(contentsOf: units)
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }
}

private extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}
