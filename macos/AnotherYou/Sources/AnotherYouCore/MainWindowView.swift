import AppKit
import SwiftUI

private enum SidebarItem: String, CaseIterable, Identifiable {
    case today, history
    var id: String { rawValue }
    var title: String { self == .today ? "今天" : "活动记录" }
    var icon: String { self == .today ? "sun.max" : "clock.arrow.circlepath" }
}

@MainActor
public struct MainWindowView: View {
    @ObservedObject private var store: AssistantStore
    @State private var selectedItem: SidebarItem = .today
    @Environment(\.openWindow) private var openWindow

    public init(store: AssistantStore) { self.store = store }

    public var body: some View {
        NavigationSplitView {
            SidebarView(selection: $selectedItem) { openWindow(id: "settings") }
        } detail: {
            switch selectedItem {
            case .today: DashboardView(store: store) { openWindow(id: "settings") }
            case .history: HistoryView(store: store)
            }
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 780, minHeight: 580)
        .task { store.connect() }
    }
}

@MainActor
private struct SidebarView: View {
    @Binding var selection: SidebarItem
    let onSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "circle.lefthalf.filled")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(Color.anotherAccent)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Another You").font(.system(size: 15, weight: .semibold, design: .rounded))
                    Text("把主动，留给恰好的时刻").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 18).padding(.top, 26).padding(.bottom, 30)

            VStack(spacing: 5) {
                ForEach(SidebarItem.allCases) { item in
                    Button { selection = item } label: {
                        Label(item.title, systemImage: item.icon)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(selection == item ? Color.anotherInk : .secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 13).padding(.vertical, 10)
                            .background(selection == item ? Color.anotherAccent.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            Spacer()
            Button(action: onSettings) { Label("设置", systemImage: "slider.horizontal.3") }
                .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.secondary)
                .padding(20)
        }
        .frame(minWidth: 205, idealWidth: 228, maxWidth: 250)
        .background(Color.anotherSidebar)
    }
}

@MainActor
private struct DashboardView: View {
    @ObservedObject var store: AssistantStore
    let onSettings: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                HeroHeader(store: store)
                if !store.modelConfigured || !store.isConnected {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(store.isConnected ? "连接你的本地模型" : store.connection.label)
                            .font(.system(size: 14, weight: .semibold))
                        if !store.isConnected {
                            Text(store.statusMessage)
                                .font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        HStack {
                            Button("模型设置", action: onSettings)
                            if !store.isConnected { Button("重新连接") { store.refresh() }.disabled(store.connection == .starting || store.isRestarting) }
                        }
                    }
                    .padding(18).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.background, in: RoundedRectangle(cornerRadius: 16))
                }
                HStack(spacing: 12) {
                    MetricTile(title: "等待决定", value: "\(store.pendingCount)", icon: "tray")
                    MetricTile(title: "生成的草稿", value: "\(store.completedCount)", icon: "doc.text")
                    MetricTile(title: "主动建议", value: store.isConnected ? (store.paused ? "已暂停" : "已开启") : "未连接", icon: "waveform.path")
                }
                VStack(alignment: .leading, spacing: 14) {
                    SectionHeading(title: "值得你看一眼", subtitle: "一条建议，一个由你决定的下一步")
                    if store.activeCards.isEmpty {
                        Text(store.connection == .starting ? "正在读取本地建议…" : "暂时没有建议。合适的时间，助手会出现在这里。")
                            .font(.system(size: 13)).foregroundStyle(.secondary)
                            .padding(24).frame(maxWidth: .infinity, alignment: .leading)
                            .background(.background, in: RoundedRectangle(cornerRadius: 18))
                    } else {
                        LazyVStack(spacing: 12) {
                            ForEach(store.activeCards) { card in
                                ProactiveCardView(card: card, busy: store.pendingActions.contains(card.id), connected: store.isConnected, modelConfigured: store.modelConfigured) { store.apply($0, to: card) }
                            }
                        }
                    }
                }
                PromptView(store: store)
            }
            .frame(maxWidth: 890, alignment: .leading)
            .padding(.horizontal, 30).padding(.vertical, 30)
            .frame(maxWidth: .infinity)
        }
        .background(Color.anotherCanvas)
    }
}

@MainActor
private struct HeroHeader: View {
    @ObservedObject var store: AssistantStore

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 9) {
                    Text(Date.now.formatted(.dateTime.month(.wide).day().weekday(.wide)))
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    Text("留一点空间，专注眼前。")
                        .font(.system(size: 27, weight: .semibold, design: .rounded)).foregroundStyle(Color.anotherInk)
                    Text("在恰好的时候，帮你往前一步。")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 10)
                Button { store.togglePause() } label: {
                    Label(store.paused ? "恢复" : "暂停", systemImage: store.paused ? "play" : "pause")
                }
                .buttonStyle(.bordered).controlSize(.small)
                .disabled(!store.isConnected || store.isChangingPause)
            }
            HStack(alignment: .top, spacing: 8) {
                Circle().fill(store.isConnected ? Color.anotherGreen : .secondary).frame(width: 6, height: 6).padding(.top, 5)
                Text(store.statusMessage).font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled)
                Spacer()
                Button { store.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).help("更新 Agent 状态").disabled(store.connection == .starting || store.isRestarting)
            }
        }
        .padding(25)
        .background(Color.anotherHero, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

private struct MetricTile: View {
    let title: String
    let value: String
    let icon: String

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                Image(systemName: icon).font(.system(size: 12)).foregroundStyle(Color.anotherAccent)
            }
            Text(value).font(.system(size: 22, weight: .semibold, design: .rounded)).foregroundStyle(Color.anotherInk)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(16)
        .background(.background, in: RoundedRectangle(cornerRadius: 16))
    }
}

private struct SectionHeading: View {
    let title: String
    var subtitle: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 17, weight: .semibold, design: .rounded)).foregroundStyle(Color.anotherInk)
            if let subtitle { Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary) }
        }
    }
}

@MainActor
private struct ProactiveCardView: View {
    let card: ProactiveCard
    let busy: Bool
    let connected: Bool
    let modelConfigured: Bool
    let onAction: (CardAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: card.kind.icon)
                    .font(.system(size: 15)).foregroundStyle(Color.anotherAccent)
                    .frame(width: 34, height: 34)
                    .background(Color.anotherAccent.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 6) {
                    Text(card.title).font(.system(size: 16, weight: .semibold)).foregroundStyle(Color.anotherInk)
                    Text(card.detail).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Text(busy ? "正在提交" : card.state.label)
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(card.state.tint)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(card.state.tint.opacity(0.09), in: Capsule())
            }
            Text(card.rationale).font(.system(size: 11)).foregroundStyle(.secondary)
            if let text = card.text, !text.isEmpty {
                Text(text).font(.system(size: 13)).lineSpacing(4).textSelection(.enabled)
                    .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.anotherCanvas, in: RoundedRectangle(cornerRadius: 12))
                if card.state == .completed {
                    Button("复制草稿", systemImage: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    }
                    .controlSize(.small)
                }
            }
            if [.pending, .failed, .snoozed].contains(card.state) {
                HStack(spacing: 9) {
                    Button(CardAction.execute.label, systemImage: CardAction.execute.icon) { onAction(.execute) }
                        .buttonStyle(.borderedProminent).tint(Color.anotherInk).disabled(!modelConfigured)
                    Button(CardAction.later.label) { onAction(.later) }
                    Button(CardAction.ignore.label) { onAction(.ignore) }.buttonStyle(.borderless).foregroundStyle(.secondary)
                    Spacer()
                }
                .controlSize(.small).disabled(busy || !connected)
            }
            if let date = card.snoozedUntil, card.state == .snoozed {
                Text("将在 \(date.formatted(date: .omitted, time: .shortened)) 再次提醒。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(19).frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 18))
    }
}

@MainActor
private struct PromptView: View {
    @ObservedObject var store: AssistantStore
    @State private var prompt = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeading(title: "也可以一起想想")
            ForEach(store.conversation) { message in
                VStack(alignment: .leading, spacing: 10) {
                    Text(message.prompt).font(.system(size: 13, weight: .medium)).textSelection(.enabled)
                    if let response = message.response {
                        Text(response).font(.system(size: 13)).lineSpacing(4).textSelection(.enabled)
                    } else if let error = message.error {
                        Text(error).font(.system(size: 12)).foregroundStyle(.red).textSelection(.enabled)
                    } else {
                        Text("正在等待本地模型回复…").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                .background(.background, in: RoundedRectangle(cornerRadius: 14))
            }
            VStack(alignment: .trailing, spacing: 10) {
                TextField("写下想梳理的一件事…", text: $prompt, axis: .vertical)
                    .lineLimit(3...8).textFieldStyle(.plain).font(.system(size: 13))
                    .disabled(!store.isConnected || !store.modelConfigured)
                Button(store.hasPendingPrompt ? "正在生成" : "发送", systemImage: "arrow.up") {
                    if store.ask(prompt) { prompt = "" }
                }
                .buttonStyle(.borderedProminent).tint(Color.anotherInk).controlSize(.small)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !store.isConnected || !store.modelConfigured || store.hasPendingPrompt)
            }
            .padding(16).background(.background, in: RoundedRectangle(cornerRadius: 16))
        }
    }
}

@MainActor
private struct HistoryView: View {
    @ObservedObject var store: AssistantStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                SectionHeading(title: "活动记录", subtitle: "每次建议、决定和生成，留有依据")
                if store.activityHistory.isEmpty {
                    Text("还没有活动记录。")
                        .font(.system(size: 13)).foregroundStyle(.secondary).padding(.vertical, 20)
                }
                LazyVStack(spacing: 10) {
                    ForEach(store.activityHistory) { event in
                        VStack(alignment: .leading, spacing: 7) {
                            HStack {
                                Text(title(for: event)).font(.system(size: 13, weight: .medium))
                                Spacer()
                                Text(event.date?.formatted(date: .abbreviated, time: .shortened) ?? "")
                                    .font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                            if let detail = event.payload["message"]?.string ?? event.payload["text"]?.string {
                                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                        }
                        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                        .background(.background, in: RoundedRectangle(cornerRadius: 14))
                    }
                }
            }
            .frame(maxWidth: 890, alignment: .leading).padding(30).frame(maxWidth: .infinity)
        }
        .background(Color.anotherCanvas)
    }

    private func title(for event: AgentEvent) -> String {
        switch event.kind {
        case "proactive.suggestion": event.payload["title"]?.string ?? "新的主动建议"
        case "proposal.updated": event.payload["state"]?.string.flatMap(CardState.init(rawValue:))?.label ?? "建议已更新"
        case "agent.response": "模型回复已生成"
        case "agent.error": "Agent 错误"
        default: event.kind
        }
    }
}

@MainActor
public struct SettingsView: View {
    @ObservedObject private var store: AssistantStore
    @State private var draft: AgentSettings
    @State private var saved = false

    public init(store: AssistantStore) {
        self.store = store
        _draft = State(initialValue: store.settings)
    }

    public var body: some View {
        Form {
            Section {
                TextField("服务地址", text: $draft.endpoint)
                TextField("模型名称", text: $draft.model, prompt: Text("例如 qwen3:8b"))
                HStack {
                    Button(store.isRestarting ? "正在重连…" : "保存并重新连接") {
                        Task { saved = await store.saveSettings(draft) }
                    }
                    .disabled(store.isRestarting)
                    if saved && store.settingsError == nil { Text("配置已保存").font(.caption).foregroundStyle(.secondary) }
                }
                if let error = store.settingsError { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            } header: { Text("本地模型") }
            Section {
                LabeledContent("主动建议", value: store.isConnected ? (store.paused ? "已暂停" : "已开启") : "Agent 未连接")
                Button(store.paused ? "恢复主动建议" : "暂停主动建议") { store.togglePause() }
                    .disabled(!store.isConnected || store.isChangingPause)
                Toggle("新建议显示系统通知", isOn: Binding(get: { store.notificationsEnabled }, set: { value in
                    Task { await store.setNotificationsEnabled(value) }
                }))
                .disabled(!store.notificationSupported)
                if !store.notificationSupported { Text("系统通知需要从 Another You.app 启动。").font(.caption).foregroundStyle(.secondary) }
                if let message = store.notificationMessage { Text(message).font(.caption).foregroundStyle(.secondary) }
            } header: { Text("介入方式") }
            Section("运行状态") {
                LabeledContent("Agent", value: store.connection.label)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 500, minHeight: 400)
        .onChange(of: draft) { _, _ in saved = false }
    }
}

private extension CardState {
    var tint: Color {
        switch self {
        case .pending, .running: .anotherAccent
        case .snoozed: .orange
        case .completed: .anotherGreen
        case .ignored: .secondary
        case .failed: .red
        }
    }
}

private extension Color {
    static let anotherInk = Color.primary
    static let anotherCanvas = Color(nsColor: .windowBackgroundColor)
    static let anotherSidebar = Color(nsColor: .controlBackgroundColor)
    static let anotherAccent = Color.indigo
    static let anotherGreen = Color.green
    static let anotherHero = Color.indigo.opacity(0.07)
}
