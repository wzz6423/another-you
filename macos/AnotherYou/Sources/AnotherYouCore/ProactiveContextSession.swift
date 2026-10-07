import Combine
import Foundation
import SwiftUI

@MainActor
public final class ProactiveContextSession: ObservableObject {
    @Published public private(set) var isRunning = false
    @Published public private(set) var enabled = true
    @Published public private(set) var tasks: [String: JSONValue] = [:]
    @Published public private(set) var intervals: [String: JSONValue] = [:]
    private let collector: any ContextCollecting
    private var collection: Task<Void, Never>?
    private var requestID: String?

    public init(collector: any ContextCollecting = SystemContextCollector()) { self.collector = collector }

    public func update(_ payload: [String: JSONValue]) {
        isRunning = payload["running"]?.bool ?? false
        enabled = payload["enabled"]?.bool ?? true
        tasks = payload["tasks"]?.object ?? [:]
        intervals = payload["intervals"]?.object ?? [:]
    }

    public func handle(_ event: AgentEvent, reply: @escaping @MainActor ([String: JSONValue]) -> Void) {
        guard let id = event.payload["requestId"]?.string else { return }
        if event.kind == "context.cancel" {
            if requestID == id { cancel() }
            return
        }
        guard event.kind == "context.request", let source = event.payload["source"]?.string, ["work", "notifications"].contains(source) else { return }
        cancel()
        requestID = id
        isRunning = true
        let collector = self.collector
        let lookbackHours: Int
        if case .number(let hours) = event.payload["lookbackHours"], [24.0, 168.0, 720.0].contains(hours) { lookbackHours = Int(hours) }
        else { lookbackHours = 24 }
        collection = Task { [weak self] in
            let result = await collector.collect(source: source, lookbackHours: lookbackHours)
            guard let self, !Task.isCancelled, self.requestID == id else { return }
            self.requestID = nil
            self.collection = nil
            self.isRunning = false
            reply(["op": .string("contextResult"), "contextResult": .object([
                "requestId": .string(id), "source": .string(source), "status": .string(result.status),
                "content": .object(result.content), "message": .string(result.message)
            ])])
        }
    }

    public func cancel() {
        collection?.cancel()
        collection = nil
        requestID = nil
        isRunning = false
    }

    func stateLabel(_ id: String) -> String {
        switch tasks[id]?.object?["state"]?.string {
        case "running": AppLocalization.text("处理中")
        case "completed": AppLocalization.text("已分析")
        case "skipped": AppLocalization.text("没有需要提醒的新变化")
        case "permission-required": AppLocalization.text("需要辅助功能权限")
        case "unavailable": AppLocalization.text("来源暂不可访问")
        case "failed": AppLocalization.text("稍后重试")
        default: AppLocalization.text("等待下一次检查")
        }
    }

    func minutes(_ key: String, fallback: Int) -> Int {
        guard case .number(let milliseconds) = intervals[key] else { return fallback }
        return Int(milliseconds / 60_000)
    }
}

struct ProactiveContextSettingsView: View {
    @Environment(\.locale) private var interfaceLocale
    @ObservedObject var session: ProactiveContextSession
    @ObservedObject var desktop: DesktopSession
    @ObservedObject var settings: LocalModelSettingsSession
    let paused: Bool

    var body: some View {
        Section(AppLocalization.text("工作与通知")) {
            Picker(AppLocalization.text("回看范围"), selection: Binding(get: { settings.workLookbackHours }, set: settings.selectWorkLookback)) {
                Text("24h").tag(24)
                Text("7d").tag(168)
                Text("30d").tag(720)
            }
            .pickerStyle(.segmented)
            .disabled(!settings.canChange)
            if paused || !session.enabled {
                Text(paused ? AppLocalization.text("主动采集与分析已暂停") : AppLocalization.text("主动采集与分析已关闭")).foregroundStyle(.secondary)
            } else {
                LabeledContent(AppLocalization.text("工作内容 · 每 %d 分钟", session.minutes("workIntervalMs", fallback: 1)), value: session.stateLabel("work"))
                LabeledContent(AppLocalization.text("通知 · 每 %d 分钟", session.minutes("notificationsIntervalMs", fallback: 1)), value: session.stateLabel("notifications"))
                LabeledContent(AppLocalization.text("发现待办后及时汇总"), value: session.stateLabel("synthesis"))
            }
            DesktopPermissionRow(session: desktop, permission: "accessibility", title: "辅助功能")
        }
    }
}
