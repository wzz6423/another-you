import AppKit
import SwiftUI

private enum SidebarItem: String, CaseIterable, Identifiable {
    case today, conversation, history
    var id: String { rawValue }
    var title: String {
        switch self { case .today: AppLocalization.text("今天"); case .conversation: AppLocalization.text("会话"); case .history: AppLocalization.text("活动记录") }
    }
    var icon: String {
        switch self { case .today: "sun.max"; case .conversation: "bubble.left.and.bubble.right"; case .history: "clock.arrow.circlepath" }
    }
}

@MainActor
public struct MainWindowView: View {
    @Environment(\.locale) private var interfaceLocale
    private let store: AssistantStore
    @State private var selectedItem: SidebarItem = .today
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(store: AssistantStore) { self.store = store }

    public var body: some View {
        NavigationSplitView {
            SidebarView(selection: $selectedItem) { openWindow(id: "settings") }
        } detail: {
            ZStack {
                Group {
                    switch selectedItem {
                    case .today: DashboardView(store: store) { selectedItem = .conversation }
                    case .conversation: ConversationWorkspaceView(store: store)
                    case .history: ActivityLogView(store: store)
                    }
                }
                .id(selectedItem)
                .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: selectedItem)
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 780, minHeight: 580)
        .task { store.connect() }
    }
}

@MainActor
private struct SidebarView: View {
    @Environment(\.locale) private var interfaceLocale
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
                    Text(AppLocalization.text("把主动，留给恰好的时刻")).font(.system(size: 10)).foregroundStyle(.secondary)
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
            Button(action: onSettings) { Label(AppLocalization.text("设置"), systemImage: "slider.horizontal.3") }
                .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.secondary)
                .padding(20)
        }
        .frame(minWidth: 205, idealWidth: 228, maxWidth: 250)
        .background(Color.anotherSidebar)
    }
}

@MainActor
private struct DashboardView: View {
    @Environment(\.locale) private var interfaceLocale
    @ObservedObject var store: AssistantStore
    let onConversation: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                UsageDashboardView(store: store)
                ConversationBoardView(store: store, onOpen: onConversation)
            }
            .frame(maxWidth: 980, alignment: .leading)
            .padding(30).frame(maxWidth: .infinity)
        }.background(Color.anotherCanvas)
    }
}

private struct SectionHeading: View {
    @Environment(\.locale) private var interfaceLocale
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
struct ProactiveCardView: View {
    @Environment(\.locale) private var interfaceLocale
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
                Text(busy ? AppLocalization.text("正在提交") : card.state.label)
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(card.state.tint)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(card.state.tint.opacity(0.09), in: Capsule())
            }
            Text(AppLocalization.text(card.rationale)).font(.system(size: 11)).foregroundStyle(.secondary)
            if let text = card.text, !text.isEmpty {
                Text(text).font(.system(size: 13)).lineSpacing(4).textSelection(.enabled)
                    .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.anotherCanvas, in: RoundedRectangle(cornerRadius: 12))
                if card.state == .completed {
                    Button(AppLocalization.text("复制草稿"), systemImage: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    }
                    .controlSize(.small)
                }
            }
            if [.pending, .failed, .snoozed].contains(card.state) {
                HStack(spacing: 9) {
                    Button(CardAction.execute.label, systemImage: CardAction.execute.icon) { onAction(.execute) }
                        .buttonStyle(.borderedProminent).tint(.blue).disabled(!modelConfigured)
                    Button(CardAction.later.label) { onAction(.later) }
                    Button(CardAction.ignore.label) { onAction(.ignore) }.buttonStyle(.borderless).foregroundStyle(.secondary)
                    Spacer()
                }
                .controlSize(.small).disabled(busy || !connected)
            }
            if let date = card.snoozedUntil, card.state == .snoozed {
                Text(AppLocalization.text("将在 %@ 再次提醒。", AppLocalization.date(date, includeDate: false)))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(19).frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 18))
    }
}

@MainActor
public struct SettingsView: View {
    @Environment(\.locale) private var interfaceLocale
    @ObservedObject private var store: AssistantStore
    @ObservedObject private var updates: UpdateController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(store: AssistantStore) {
        self.store = store
        updates = store.updates
    }

    private enum Page: String, CaseIterable, Identifiable {
        case general = "通用", model = "模型", suggestions = "主动建议"
        case desktop = "电脑操作", shortcuts = "快捷键", updates = "软件更新"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .general: "gearshape"
            case .model: "cpu"
            case .suggestions: "bell"
            case .desktop: "desktopcomputer"
            case .shortcuts: "keyboard"
            case .updates: "arrow.down.circle"
            }
        }
    }

    @State private var page: Page = .general

    public var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 5) {
                ForEach(Page.allCases) { item in
                    Button { page = item } label: {
                        Label(AppLocalization.text(item.rawValue), systemImage: item.icon)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12).padding(.vertical, 10)
                            .background(page == item ? Color.accentColor.opacity(0.12) : .clear,
                                        in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(page == item ? .isSelected : [])
                }
                Spacer()
            }
            .padding(12).frame(width: 160)
            .background(Color(nsColor: .controlBackgroundColor))
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                Text(AppLocalization.text(page.rawValue)).font(.title2.bold()).padding(.horizontal, 22).padding(.top, 22)
                Form {
                    switch page {
                    case .general: generalSettings
                    case .model: modelSettings
                    case .suggestions: suggestionSettings
                    case .desktop: DesktopSettingsView(session: store.desktop)
                    case .shortcuts: ShortcutSettingsView()
                    case .updates: updateSettings
                    }
                }
                .formStyle(.grouped)
                .id(page)
                .transition(.opacity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: page)
        .frame(minWidth: 680, minHeight: 520)
        .background(LocalizedWindowTitle(key: "设置").frame(width: 0, height: 0))
        .task { updates.start() }
    }

    private var generalSettings: some View {
        Group {
            LanguageSettingsView()
            Section(AppLocalization.text("外观")) {
                Picker(AppLocalization.text("模式"), selection: Binding(get: { store.appearance }, set: store.setAppearance)) {
                    ForEach(AppAppearance.allCases) { appearance in
                        Text(appearance.title(locale: interfaceLocale)).tag(appearance)
                    }
                }
                .pickerStyle(.segmented)
            }
        }
    }

    private var modelSettings: some View {
        ModelSettingsView(session: store.modelSettings, modelsFileURL: store.modelsFileURL)
    }

    private var suggestionSettings: some View {
        Group {
            Section {
                LabeledContent(AppLocalization.text("主动建议"), value: store.isConnected ? (store.paused ? AppLocalization.text("已暂停") : AppLocalization.text("已开启")) : AppLocalization.text("Agent 未连接"))
                Button(store.paused ? AppLocalization.text("恢复主动建议") : AppLocalization.text("暂停主动建议")) { store.togglePause() }
                    .disabled(!store.isConnected || store.isChangingPause)
                Toggle(AppLocalization.text("新建议显示系统通知"), isOn: Binding(get: { store.notificationsEnabled }, set: { value in
                    Task { await store.setNotificationsEnabled(value) }
                }))
                .disabled(!store.notificationSupported)
                if !store.notificationSupported { Text(AppLocalization.text("系统通知需要从 Another You.app 启动。")).font(.caption).foregroundStyle(.secondary) }
                if let message = store.notificationMessage { Text(AppLocalization.text(message)).font(.caption).foregroundStyle(.secondary) }
            } header: { Text(AppLocalization.text("介入方式")) }
            ProactiveContextSettingsView(session: store.proactiveContext, paused: store.paused)
        }
    }

    private var updateSettings: some View {
        Group {
            Section(AppLocalization.text("软件更新")) {
                LabeledContent(AppLocalization.text("版本"), value: AppLocalization.text(updates.version))
                Toggle(AppLocalization.text("自动检查更新"), isOn: Binding(get: { updates.automaticallyChecks }, set: updates.setAutomaticChecks))
                    .disabled(!updates.allowsAutomaticUpdates)
                Toggle(AppLocalization.text("自动下载更新"), isOn: Binding(get: { updates.automaticallyDownloads }, set: updates.setAutomaticDownloads))
                    .disabled(!updates.allowsAutomaticUpdates || !updates.automaticallyChecks)
                Toggle(AppLocalization.text("自动安装更新"), isOn: Binding(get: { updates.automaticallyInstalls }, set: updates.setAutomaticInstalls))
                    .disabled(!updates.allowsAutomaticUpdates || !updates.automaticallyDownloads)
                Text(AppLocalization.text("开启后，当前任务完成时自动安装并重启。")).font(.caption).foregroundStyle(.secondary)
                Button(AppLocalization.text("检查更新…"), action: updates.checkForUpdates).disabled(!updates.canCheck)
                if let status = updates.status { Text(AppLocalization.message(status)).font(.caption).foregroundStyle(.secondary) }
            }
        }
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
}
