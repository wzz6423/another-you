import SwiftUI

struct ActivityDetail {
    let event: AgentEvent
    let related: [AgentEvent]
    let usage: UsageRecord?

    init(event: AgentEvent, history: [AgentEvent], records: [UsageRecord]) {
        self.event = event
        let runID = event.payload["runId"]?.string
        let requestID = event.payload["requestId"]?.string
        let suggestionID = event.payload["suggestionId"]?.string
        related = history.filter { other in
            if let runID { return other.payload["runId"]?.string == runID }
            if let requestID { return other.payload["requestId"]?.string == requestID }
            if let suggestionID { return other.payload["suggestionId"]?.string == suggestionID }
            return other.id == event.id
        }
        let candidates = records.filter { record in
            if let runID { return record.runId == runID }
            if let requestID { return record.requestId == requestID }
            if let suggestionID { return record.suggestionId == suggestionID }
            return false
        }
        usage = candidates.count == 1 ? candidates[0] : nil
    }

    func value(_ key: String) -> String? {
        if let value = event.payload[key]?.string, !value.isEmpty { return value }
        let matches = related.filter { other in
            if ["input", "result", "action", "targetAppName", "targetBundleId", "targetWindowTitle"].contains(key) {
                return other.payload["toolCallId"]?.string == event.payload["toolCallId"]?.string
            }
            return true
        }
        return matches.sorted { $0.occurredAt > $1.occurredAt }.compactMap { $0.payload[key]?.string }.first { !$0.isEmpty }
    }

    private var isDesktopAction: Bool { event.payload["toolName"]?.string == "computer_use" }

    var application: String? {
        isDesktopAction ? value("targetAppName") : value("appName") ?? usage?.appName
    }
    var windowTitle: String? {
        isDesktopAction ? value("targetWindowTitle") : value("windowTitle") ?? usage?.windowTitle
    }
    var bundleID: String? {
        isDesktopAction ? value("targetBundleId") : value("bundleId") ?? usage?.bundleId
    }
    var duration: Double? {
        if case .number(let value) = event.payload["durationMs"] { return value }
        if let toolID = event.payload["toolCallId"]?.string {
            let events = related.filter { $0.payload["toolCallId"]?.string == toolID }
            guard let start = events.first(where: { $0.payload["phase"]?.string == "started" })?.date,
                  let end = events.first(where: { ["completed", "failed"].contains($0.payload["phase"]?.string ?? "") })?.date else { return nil }
            return max(0, end.timeIntervalSince(start) * 1000)
        }
        if let requestID = event.payload["requestId"]?.string, event.payload["category"]?.string == "context",
           let completed = related.first(where: { $0.payload["requestId"]?.string == requestID && $0.payload["durationMs"] != nil }),
           case .number(let value) = completed.payload["durationMs"] { return value }
        return usage?.durationMs
    }

    var model: String? { usage?.model ?? value("model") }
    var route: String? { usage?.route ?? value("route") }
    var reasoningEffort: String? { usage?.reasoningEffort ?? value("reasoningEffort") }

    var output: String? {
        if event.payload["toolCallId"] != nil { return Self.readable(value("result")) }
        return Self.readable(value("draft") ?? value("text") ?? value("result"))
    }

    static func readable(_ text: String?) -> String? {
        guard let text, let data = text.data(using: .utf8),
              let json = try? JSONDecoder().decode(JSONValue.self, from: data), let fields = json.object else { return text }
        for key in ["draft", "summary", "message", "text"] {
            if let value = fields[key]?.string, !value.isEmpty { return value }
        }
        if let content = fields["content"]?.array {
            let parts = content.compactMap { $0.object?["text"]?.string }
            if !parts.isEmpty { return parts.joined(separator: "\n") }
        }
        if let items = fields["items"]?.array { return items.compactMap(\.string).joined(separator: "\n\n") }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(json)).flatMap { String(data: $0, encoding: .utf8) } ?? text
    }
}

@MainActor
struct ActivityDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @ObservedObject var store: AssistantStore
    let event: AgentEvent

    private var detail: ActivityDetail { ActivityDetail(event: event, history: store.history, records: store.usageRecords) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(AppLocalization.text("执行详情")).font(.title2.bold())
                Spacer()
                Button(AppLocalization.text("关闭")) { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(detail.value("action") ?? event.activityTitle(locale: locale)).font(.headline)
                    Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 10) {
                        field("发生时间", event.date.map { $0.formatted(.dateTime.year().month().day().hour().minute().second().locale(locale)) })
                        field("应用", detail.application)
                        if let name = detail.windowTitle { field("窗口", name) }
                        if let bundle = detail.bundleID { field("应用标识", bundle) }
                        field("执行来源", sourceTitle(detail.value("source") ?? event.source))
                        field("状态", AppLocalization.text(detail.value("phase") == "failed" ? "失败" : detail.value("phase") == "started" ? "开始" : "已完成"))
                        if let duration = detail.duration { field("耗时", String(format: "%.2f s", locale: locale, duration / 1000)) }
                    }
                    textBlock("处理原因", detail.value("reason"))
                    textBlock("说明", detail.value("message"))
                    textBlock("输入内容", ActivityDetail.readable(detail.value("input") ?? detail.value("prompt")))
                    textBlock("执行结果", detail.output)
                    Divider()
                    Text(AppLocalization.text("模型调用")).font(.headline)
                    Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 10) {
                        field("运行位置", detail.route.map { AppLocalization.text($0 == "local" ? "本地" : "远端") })
                        field("模型", detail.model)
                        field("提供方", detail.usage?.provider ?? detail.value("provider"))
                        field("思考深度", detail.reasoningEffort.map { AppLocalization.reasoningEffort($0, locale: locale) })
                        field("接口地址 (Base URL)", detail.usage?.endpoint ?? detail.value("endpoint"))
                        if let path = detail.usage?.requestPath ?? detail.value("requestPath") { field("请求路径", path) }
                    }
                    if let tokens = detail.usage?.usage {
                        Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 10) {
                            field("输入 Token", AppLocalization.number(tokens.inputTokens + tokens.cacheReadTokens + tokens.cacheWriteTokens))
                            field("输出 Token", AppLocalization.number(tokens.outputTokens))
                            field("缓存读取 Token", detail.usage?.provider == "ollama" ? AppLocalization.text("未报告") : AppLocalization.number(tokens.cacheReadTokens))
                            field("缓存写入 Token", detail.usage?.provider == "ollama" ? AppLocalization.text("未报告") : AppLocalization.number(tokens.cacheWriteTokens))
                            field("总 Token", AppLocalization.number(tokens.totalTokens))
                        }
                    } else {
                        Text(AppLocalization.text("此记录没有可关联的 Token 用量。")).font(.callout).foregroundStyle(.secondary)
                    }
                    if let calls = detail.usage?.toolCalls, !calls.isEmpty {
                        textBlock("工具调用", calls.map { "\($0.kind) · \($0.name)" }.joined(separator: "\n"))
                    }
                    DisclosureGroup(AppLocalization.text("请求标识")) {
                        Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 10) {
                            field("事件 ID", event.id)
                            field("执行 ID", detail.value("runId") ?? detail.usage?.runId)
                            field("请求 ID", detail.value("requestId") ?? detail.usage?.requestId)
                            if let id = detail.usage?.upstreamRequestId ?? detail.value("upstreamRequestId") { field("上游请求 ID", id) }
                            if let id = detail.value("conversationId") { field("会话 ID", id) }
                        }.padding(.top, 10)
                    }
                }.padding(24).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            }
        }.frame(minWidth: 540, idealWidth: 680, maxWidth: 840, minHeight: 420, idealHeight: 650, maxHeight: 800)
    }

    private func field(_ title: String, _ value: String?) -> some View {
        GridRow(alignment: .top) {
            Text(AppLocalization.text(title)).foregroundStyle(.secondary).frame(width: 125, alignment: .leading)
            Text(value?.isEmpty == false ? value! : AppLocalization.text("未记录")).frame(maxWidth: .infinity, alignment: .leading)
        }.font(.callout)
    }

    @ViewBuilder
    private func textBlock(_ title: String, _ text: String?) -> some View {
        if let text, !text.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(AppLocalization.text(title)).font(.subheadline.bold())
                Text(text).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func sourceTitle(_ value: String) -> String {
        AppLocalization.text(["prompt": "手动会话", "proposal": "建议执行", "context-analyst": "工作内容分析", "notification-analyst": "通知分析",
                              "proactive-parent": "建议汇总", "proactive": "主动判断", "context": "上下文采集", "scheduler": "定时规则", "agent": "助手" ][value] ?? value)
    }
}
