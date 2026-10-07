import AppKit
import Combine
import SwiftUI

public struct ScreenAttachment: Identifiable, Sendable, Equatable {
    public let id = UUID()
    public let capture: DesktopCapture
    public var payload: JSONValue {
        .object(["data": .string(capture.imageData.base64EncodedString()),
                 "mimeType": .string(capture.mimeType), "context": .object(capture.context)])
    }
}

@MainActor
public final class DesktopSession: ObservableObject {
    @Published public private(set) var attachments: [ScreenAttachment] = []
    @Published public private(set) var isCapturing = false
    @Published public private(set) var isPreparingSnapshot = false
    @Published public private(set) var error: String?
    @Published public private(set) var activity: String?
    @Published public var allowForeground = false
    @Published public private(set) var permissions: [String: JSONValue] = [:]
    var canStartOperation: () -> Bool = { true }
    private let desktop: DesktopAutomation
    private let captureImage: (DesktopCaptureMode, pid_t?) async throws -> DesktopCapture
    private let captureSnapshotImage: (pid_t, [String: JSONValue]) async throws -> DesktopCapture
    private let readContext: (pid_t) throws -> [String: JSONValue]
    private let frontmostPID: () -> pid_t?
    private var lastExternalPID: pid_t?
    private var activationObserver: AnyCancellable?
    private var captureTask: Task<Void, Never>?
    private var snapshotTask: Task<[String: JSONValue], Never>?
    private var snapshotGeneration = UUID()
    private var operations: [String: Task<Void, Never>] = [:]
    private var generation = UUID()

    public convenience init() {
        let service = DesktopAutomation()
        self.init(capture: { mode, pid in try await service.capture(mode: mode, targetPID: pid) },
                  snapshotCapture: { pid, context in try await service.captureInvocationImage(pid: pid, context: context) }, desktop: service)
    }

    init(capture: @escaping (DesktopCaptureMode, pid_t?) async throws -> DesktopCapture,
         snapshotCapture: ((pid_t, [String: JSONValue]) async throws -> DesktopCapture)? = nil,
         context: ((pid_t) throws -> [String: JSONValue])? = nil,
         frontmostPID: @escaping () -> pid_t? = { DesktopAutomation.frontmostApplicationPID },
         desktop: DesktopAutomation = DesktopAutomation()) {
        self.desktop = desktop
        captureImage = capture
        captureSnapshotImage = snapshotCapture ?? { pid, context in try await capture(context["windowId"] == nil ? .screen : .window, pid) }
        readContext = context ?? { pid in try desktop.context(targetPID: pid, pinTarget: true) }
        self.frontmostPID = frontmostPID
        rememberCurrentApplication()
        permissions = desktop.capabilities
        activationObserver = NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didActivateApplicationNotification)
            .sink { [weak self] notification in
                guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                let pid = app.processIdentifier
                Task { @MainActor [weak self] in
                    if pid != ProcessInfo.processInfo.processIdentifier { self?.lastExternalPID = pid }
                }
            }
    }

    public func rememberCurrentApplication() {
        if let pid = frontmostPID(), pid != ProcessInfo.processInfo.processIdentifier { lastExternalPID = pid }
    }

    func prepareInvocationSnapshot() -> Task<[String: JSONValue], Never> {
        snapshotTask?.cancel()
        let current = UUID()
        snapshotGeneration = current
        isPreparingSnapshot = true
        rememberCurrentApplication()
        let pid = lastExternalPID
        var snapshot: [String: JSONValue] = ["capturedAt": .string(ISO8601DateFormatter().string(from: Date())), "context": .object([:])]
        let canCapture = canStartOperation() && pid != nil
        if canCapture, let pid {
            do { snapshot["context"] = .object(try readContext(pid)) }
            catch { snapshot["contextError"] = .string(String(error.localizedDescription.prefix(2000))) }
        } else {
            let error = DesktopAutomationError.unavailable("唤起输入框时无法采集目标应用").localizedDescription
            snapshot["contextError"] = .string(error)
            snapshot["screenshotError"] = .string(error)
        }
        let initial = snapshot
        let task = Task { [weak self] in
            guard let self else { return initial }
            defer {
                if snapshotGeneration == current { isPreparingSnapshot = false; snapshotTask = nil }
            }
            var result = initial
            guard canCapture, let pid else { return result }
            do {
                try Task.checkCancellation()
                let capture = try await captureSnapshotImage(pid, initial["context"]?.object ?? [:])
                try Task.checkCancellation()
                result["image"] = capture.json["image"]
                result["mode"] = .string(capture.mode.rawValue)
            } catch { result["screenshotError"] = .string(String(error.localizedDescription.prefix(2000))) }
            return result
        }
        snapshotTask = task
        return task
    }

    public func capture(_ mode: DesktopCaptureMode, completion: (@MainActor () -> Void)? = nil) {
        guard canStartOperation() else { error = AppLocalization.text("更新正在安装，请稍后重试。"); return }
        guard !isCapturing else { return }
        guard attachments.count < 4 else { error = AppLocalization.text("最多附加 4 张截图，请先发送或移除。"); return }
        rememberCurrentApplication()
        let pid = lastExternalPID
        isCapturing = true
        error = nil
        captureTask = Task { [weak self] in
            guard let self else { return }
            defer { self.isCapturing = false; self.captureTask = nil }
            do {
                let result = try await captureImage(mode, pid)
                try Task.checkCancellation()
                attachments.append(ScreenAttachment(capture: result))
                completion?()
            } catch is CancellationError { }
            catch DesktopAutomationError.cancelled { }
            catch { self.error = error.localizedDescription; completion?() }
            refreshPermissions()
        }
    }

    public func removeAttachment(_ id: UUID) { attachments.removeAll { $0.id == id } }
    public func clearAttachments() { attachments.removeAll() }
    func replaceAttachments(_ values: [ScreenAttachment]) {
        captureTask?.cancel()
        attachments = values
        error = nil
    }
    public func refreshPermissions() { permissions = desktop.capabilities }
    public func requestPermission(_ name: String) async {
        do { permissions = try await desktop.handle(["action": .string("requestPermissions"), "permission": .string(name)]) }
        catch { self.error = error.localizedDescription }
    }

    public func handle(_ event: AgentEvent, reply: @escaping @MainActor ([String: JSONValue]) -> Void) {
        guard let id = event.payload["requestId"]?.string else { return }
        if event.kind == "desktop.cancel" {
            operations.removeValue(forKey: id)?.cancel()
            if operations.isEmpty { activity = nil }
            return
        }
        guard event.kind == "desktop.request", var arguments = event.payload["arguments"]?.object else { return }
        guard canStartOperation() else {
            reply(["op": .string("desktopResult"), "requestId": .string(id), "error": .string(AppLocalization.text("更新正在安装，请稍后重试。"))])
            return
        }
        guard operations.isEmpty else {
            reply(["op": .string("desktopResult"), "requestId": .string(id), "error": .string(AppLocalization.text("另一个电脑操作仍在执行，请稍后重试。"))])
            return
        }
        if arguments["background"]?.bool == false && !allowForeground {
            reply(["op": .string("desktopResult"), "requestId": .string(id), "error": .string(AppLocalization.text("前台控制未开启。"))])
            return
        }
        if arguments["pid"] == nil, let lastExternalPID { arguments["pid"] = .number(Double(lastExternalPID)) }
        let current = generation
        activity = AppLocalization.text("电脑：%@", arguments["action"]?.string ?? AppLocalization.text("操作"))
        operations[id] = Task { [weak self] in
            guard let self else { return }
            defer {
                operations.removeValue(forKey: id)
                if operations.isEmpty { activity = nil }
            }
            do {
                let result = try await desktop.handle(arguments)
                guard !Task.isCancelled, generation == current else { return }
                reply(["op": .string("desktopResult"), "requestId": .string(id), "result": .object(result)])
            } catch {
                guard !Task.isCancelled, generation == current else { return }
                reply(["op": .string("desktopResult"), "requestId": .string(id), "error": .string(error.localizedDescription)])
            }
        }
    }

    public func cancel() {
        generation = UUID()
        captureTask?.cancel()
        snapshotTask?.cancel()
        for operation in operations.values { operation.cancel() }
        operations.removeAll()
        activity = nil
    }
}

struct CaptureAttachmentsView: View {
    @Environment(\.locale) private var interfaceLocale
    @ObservedObject var session: DesktopSession

    var body: some View {
        if !session.attachments.isEmpty {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(session.attachments) { attachment in
                        VStack(alignment: .leading, spacing: 4) {
                            if let image = NSImage(data: attachment.capture.imageData) {
                                Image(nsImage: image).resizable().scaledToFit().frame(width: 140, height: 88)
                            }
                            HStack {
                                Text(attachment.capture.context["appName"]?.string ?? AppLocalization.text("截图")).font(.caption).lineLimit(1)
                                Spacer()
                                Button { session.removeAttachment(attachment.id) } label: { Image(systemName: "xmark.circle.fill") }
                                    .buttonStyle(.plain).accessibilityLabel(AppLocalization.text("移除截图"))
                            }
                        }.frame(width: 140).padding(8).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }
        if let error = session.error { Text(AppLocalization.text(error)).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
    }
}

public struct DesktopSettingsView: View {
    @Environment(\.locale) private var interfaceLocale
    @ObservedObject var session: DesktopSession
    public init(session: DesktopSession) { self.session = session }

    public var body: some View {
        Section(AppLocalization.text("电脑操作")) {
            DesktopPermissionRow(session: session, permission: "screenRecording", title: "屏幕录制")
            DesktopPermissionRow(session: session, permission: "accessibility", title: "辅助功能")
            Text(AppLocalization.text("读取应用内容、截图并操作控件。前台控制可在会话中单独允许。"))
                .font(.caption).foregroundStyle(.secondary)
            if let error = session.error { Text(AppLocalization.text(error)).font(.caption).foregroundStyle(.red) }
        }
    }
}

struct DesktopPermissionRow: View {
    @ObservedObject var session: DesktopSession
    let permission: String
    let title: String

    var body: some View {
        HStack {
            Text(AppLocalization.text(title))
            Spacer()
            if session.permissions[permission + "Granted"]?.bool == true { Label(AppLocalization.text("已允许"), systemImage: "checkmark.circle").foregroundStyle(.secondary) }
            else { Button(AppLocalization.text("授权")) { Task { await session.requestPermission(permission) } } }
        }
        .onAppear { session.refreshPermissions() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in session.refreshPermissions() }
    }
}
