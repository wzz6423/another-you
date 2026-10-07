import AppKit
import ApplicationServices
import CryptoKit
import Foundation

public struct ContextSnapshot: Sendable {
    public let status: String
    public let content: [String: JSONValue]
    public let message: String

    public init(status: String, content: [String: JSONValue] = [:], message: String = "") {
        self.status = status
        self.content = content
        self.message = message
    }
}

public protocol ContextCollecting: Sendable {
    func collect(source: String) async -> ContextSnapshot
    func collect(source: String, lookbackHours: Int) async -> ContextSnapshot
}

extension ContextCollecting {
    public func collect(source: String, lookbackHours: Int) async -> ContextSnapshot { await collect(source: source) }
}

protocol ContextAccessibility {
    associatedtype Element
    func string(_ attribute: String, from element: Element) -> String?
    func protectedContent(_ element: Element) -> Bool
    func children(_ element: Element, limit: Int) -> [Element]
}

struct ContextTextReader<Access: ContextAccessibility> {
    let access: Access
    var remainingNodes = 160
    var remainingCharacters = 12_000
    var maximumAttributeCharacters = 12_000
    let deadline: Date
    var truncated = false

    mutating func read(_ element: Access.Element, depth: Int = 0) -> [String] {
        guard remainingNodes > 0, remainingCharacters > 0, depth < 14, Date() < deadline, !Task.isCancelled else { truncated = true; return [] }
        remainingNodes -= 1
        // 安全文本控件的整个子树都跳过，避免从 description 或子控件泄漏。
        guard !access.protectedContent(element) else { return [] }
        var text: [String] = []
        for attribute in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute] {
            guard Date() < deadline, remainingCharacters > 0, !Task.isCancelled else { break }
            guard let raw = access.string(attribute, from: element)?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { continue }
            let value = String(raw.prefix(min(maximumAttributeCharacters, remainingCharacters)))
            if value != raw { truncated = true }
            if !text.contains(value) { text.append(value); remainingCharacters -= value.count }
        }
        guard Date() < deadline, remainingNodes > 0, remainingCharacters > 0, !Task.isCancelled else { return text }
        for child in access.children(element, limit: remainingNodes) {
            text += read(child, depth: depth + 1)
            if remainingNodes <= 0 || remainingCharacters <= 0 || Date() >= deadline || Task.isCancelled { break }
        }
        return text
    }
}

private struct ContextAXAccess: ContextAccessibility {
    func attribute(_ name: String, from element: AXUIElement) -> CFTypeRef? {
        AXUIElementSetMessagingTimeout(element, 0.1)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    func string(_ attribute: String, from element: AXUIElement) -> String? { self.attribute(attribute, from: element) as? String }
    func protectedContent(_ element: AXUIElement) -> Bool {
        string(kAXSubroleAttribute, from: element) == kAXSecureTextFieldSubrole || attribute("AXProtectedContent", from: element) as? Bool == true
    }
    func children(_ element: AXUIElement, limit: Int) -> [AXUIElement] { elements(kAXChildrenAttribute, from: element, limit: limit) }
    func elements(_ attribute: String, from element: AXUIElement, limit: Int) -> [AXUIElement] {
        guard limit > 0 else { return [] }
        AXUIElementSetMessagingTimeout(element, 0.1)
        var value: CFArray?
        guard AXUIElementCopyAttributeValues(element, attribute as CFString, 0, limit, &value) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }
}

public actor SystemContextCollector: ContextCollecting {
    private struct Target: Sendable {
        let pid: pid_t
        let appName: String
        let bundleID: String
    }

    public init() {}
    private var workApplicationCursor = 0
    private var workCollectionRound = 0
    private var workWindowCursor = WorkContextCursor()
    private let localWorkCollector = LocalWorkContextCollector()

    public func collect(source: String) async -> ContextSnapshot {
        await collect(source: source, lookbackHours: 24)
    }

    public func collect(source: String, lookbackHours: Int) async -> ContextSnapshot {
        guard source == "work" || source == "notifications" else { return ContextSnapshot(status: "unavailable", message: "不支持的采集来源") }
        guard Self.sessionActive, !Task.isCancelled else { return ContextSnapshot(status: "unavailable", message: "会话锁定或采集已取消") }
        if source == "work" {
            let hours = [24, 168, 720].contains(lookbackHours) ? lookbackHours : 24
            let applications: [Target] = await MainActor.run {
                NSWorkspace.shared.runningApplications.filter {
                    !$0.isTerminated && $0.activationPolicy == .regular && $0.processIdentifier != getpid()
                        && !($0.bundleIdentifier?.hasPrefix("com.anotheryou.") ?? false)
                }.map { Target(pid: $0.processIdentifier, appName: $0.localizedName ?? "未知应用", bundleID: $0.bundleIdentifier ?? "") }
                    .sorted { $0.pid < $1.pid }
            }
            let round = workCollectionRound
            workCollectionRound += 1
            async let local = localWorkCollector.collect(lookbackHours: hours, applicationPIDs: applications.map(\.pid), samplingRound: round)
            let windows = workWindows(applications)
            let sources = await local
            guard Self.sessionActive, !Task.isCancelled else { return ContextSnapshot(status: "unavailable", message: "会话锁定或采集已取消") }
            return WorkContextSourceResult.snapshot([windows] + sources, lookbackHours: hours)
        }
        guard AXIsProcessTrusted() else {
            return ContextSnapshot(status: "permission-required", message: "需要在系统设置中允许 Another You 使用辅助功能后，才能读取工作窗口和可访问的通知。")
        }
        let target: Target? = await MainActor.run {
            let app = NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == "com.apple.notificationcenterui" }
            guard let app, !app.isTerminated, app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
            return Target(pid: app.processIdentifier, appName: app.localizedName ?? "未知应用", bundleID: app.bundleIdentifier ?? "")
        }
        guard let target, Self.sessionActive, !Task.isCancelled else {
            return ContextSnapshot(status: "unavailable", message: source == "work" ? "当前没有可读取的外部工作窗口" : "通知中心当前不可访问")
        }
        let access = ContextAXAccess()
        let root = AXUIElementCreateApplication(target.pid)
        var reader = ContextTextReader(access: access, maximumAttributeCharacters: 1500, deadline: Date().addingTimeInterval(2))
        let result: ContextSnapshot
        do {
            let windows = access.elements(kAXWindowsAttribute, from: root, limit: 12)
            var items: [JSONValue] = []
            for window in windows {
                let text = reader.read(window).joined(separator: "\n")
                if !text.isEmpty, !text.contains("Another You"), !text.contains("AnotherYou") { items.append(.string(text)) }
                if Date() >= reader.deadline || Task.isCancelled { break }
            }
            guard !items.isEmpty else {
                return ContextSnapshot(status: "unavailable", message: "当前没有辅助功能可访问的通知；无法确认其他应用是否收到了新通知。")
            }
            result = ContextSnapshot(status: "ok", content: ["appName": .string(target.appName), "bundleId": .string(target.bundleID),
                "items": .array(items), "scope": .string("仅当前可访问的通知窗口，可能遗漏已消失的通知")])
        }
        guard Self.sessionActive, !Task.isCancelled else { return ContextSnapshot(status: "unavailable", message: "会话锁定或采集已取消") }
        return result
    }

    private func workWindows(_ applications: [Target]) -> WorkContextSourceResult {
        var result = WorkContextSourceResult()
        guard AXIsProcessTrusted() else {
            result.note("application", status: "permission-required", message: "辅助功能尚未授权，无法补充各应用的窗口正文；其他本机来源仍可读取。")
            return result
        }
        let access = ContextAXAccess()
        let deadline = Date().addingTimeInterval(5)
        var limited = applications.count > 24
        let offset = applications.isEmpty ? 0 : workApplicationCursor % applications.count
        let ordered = Array(applications.dropFirst(offset)) + applications.prefix(offset)
        var visited = 0
        for app in ordered.prefix(24) {
            guard Date() < deadline, Self.sessionActive, !Task.isCancelled else { limited = true; break }
            visited += 1
            let root = AXUIElementCreateApplication(app.pid)
            let windows = access.elements(kAXWindowsAttribute, from: root, limit: 64)
            if windows.count > 12 { limited = true }
            let source = "windows:\(app.pid)"
            var visitedWindows = 0
            for window in workWindowCursor.page(windows, source: source, limit: 12) {
                guard Date() < deadline, Self.sessionActive, !Task.isCancelled else { limited = true; break }
                visitedWindows += 1
                var reader = ContextTextReader(access: access, remainingNodes: 500, remainingCharacters: 24_000,
                    deadline: min(deadline, Date().addingTimeInterval(0.6)))
                let text = reader.read(window).joined(separator: "\n")
                let title = access.string(kAXTitleAttribute, from: window) ?? app.appName
                var details: [String: JSONValue] = ["pid": .number(Double(app.pid)), "appName": .string(app.appName),
                    "bundleId": .string(app.bundleID), "windowTitle": .string(String(title.prefix(500)))]
                if let document = access.string(kAXDocumentAttribute, from: window), let url = URL(string: document), url.isFileURL {
                    details["path"] = .string(url.path)
                    if Date() < deadline, let item = WorkDocumentReader.item(url, observedAt: Date(),
                        details: ["appName": .string(app.appName), "bundleId": .string(app.bundleID), "activity": .string("open-document")]) { result.items.append(item) }
                }
                let hash = SHA256.hash(data: Data(title.utf8)).map { String(format: "%02x", $0) }.joined()
                let windowID = (access.attribute("AXWindowNumber", from: window) as? NSNumber)?.stringValue ?? String(CFHash(window))
                let truncated = reader.truncated || reader.remainingCharacters <= 0 || reader.remainingNodes <= 0 || Date() >= reader.deadline
                result.items.append(WorkContextItem(id: "window:\(app.bundleID):\(app.pid):\(windowID):\(hash)", source: "application", title: title,
                    text: text.isEmpty ? nil : text, observedAt: Date(), contentStatus: text.isEmpty ? "metadata-only" : truncated ? "truncated" : "complete", details: details))
            }
            workWindowCursor.advance(source: source, visited: visitedWindows, total: windows.count)
        }
        workApplicationCursor = offset + max(1, visited)
        result.note("application", status: limited ? "partial" : "ok", message: "后台读取多个运行应用提供的窗口文本；不切换焦点、不截图，应用未暴露的内容不可读取。")
        return result
    }

    private static var sessionActive: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return session[kCGSessionOnConsoleKey as String] as? Bool == true
            && session["CGSSessionScreenIsLocked"] as? Bool != true
    }
}
