import AppKit
import ApplicationServices
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
    let deadline: Date

    mutating func read(_ element: Access.Element, depth: Int = 0) -> [String] {
        guard remainingNodes > 0, remainingCharacters > 0, depth < 10, Date() < deadline, !Task.isCancelled else { return [] }
        remainingNodes -= 1
        // 安全文本控件的整个子树都跳过，避免从 description 或子控件泄漏。
        guard !access.protectedContent(element) else { return [] }
        var text: [String] = []
        for attribute in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute] {
            guard Date() < deadline, remainingCharacters > 0, !Task.isCancelled else { break }
            guard let raw = access.string(attribute, from: element)?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { continue }
            let value = String(raw.prefix(min(1500, remainingCharacters)))
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

    public func collect(source: String) async -> ContextSnapshot {
        guard source == "work" || source == "notifications" else { return ContextSnapshot(status: "unavailable", message: "不支持的采集来源") }
        guard Self.sessionActive, !Task.isCancelled else { return ContextSnapshot(status: "unavailable", message: "会话锁定或采集已取消") }
        guard AXIsProcessTrusted() else {
            return ContextSnapshot(status: "permission-required", message: "需要在系统设置中允许 Another You 使用辅助功能后，才能读取工作窗口和可访问的通知。")
        }
        let target: Target? = await MainActor.run {
            let app = source == "work" ? NSWorkspace.shared.frontmostApplication
                : NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == "com.apple.notificationcenterui" }
            guard let app, !app.isTerminated, app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
            return Target(pid: app.processIdentifier, appName: app.localizedName ?? "未知应用", bundleID: app.bundleIdentifier ?? "")
        }
        guard let target, Self.sessionActive, !Task.isCancelled else {
            return ContextSnapshot(status: "unavailable", message: source == "work" ? "当前没有可读取的外部工作窗口" : "通知中心当前不可访问")
        }
        let access = ContextAXAccess()
        let root = AXUIElementCreateApplication(target.pid)
        var reader = ContextTextReader(access: access, deadline: Date().addingTimeInterval(2))
        let result: ContextSnapshot
        if source == "work" {
            guard let value = access.attribute(kAXFocusedWindowAttribute, from: root), CFGetTypeID(value) == AXUIElementGetTypeID() else {
                return ContextSnapshot(status: "unavailable", message: "当前应用没有提供可访问的工作窗口")
            }
            let window = unsafeDowncast(value, to: AXUIElement.self)
            let text = reader.read(window)
            guard !text.isEmpty else { return ContextSnapshot(status: "unavailable", message: "当前窗口未提供可读取的文本") }
            result = ContextSnapshot(status: "ok", content: ["appName": .string(target.appName), "bundleId": .string(target.bundleID), "text": .string(text.joined(separator: "\n"))])
        } else {
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
            result = ContextSnapshot(status: "ok", content: ["items": .array(items), "scope": .string("仅当前可访问的通知窗口，可能遗漏已消失的通知")])
        }
        guard Self.sessionActive, !Task.isCancelled else { return ContextSnapshot(status: "unavailable", message: "会话锁定或采集已取消") }
        return result
    }

    private static var sessionActive: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return session[kCGSessionOnConsoleKey as String] as? Bool == true
            && session["CGSSessionScreenIsLocked"] as? Bool != true
    }
}
