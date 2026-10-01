import AppKit
import SwiftUI

private enum SidebarItem: String, CaseIterable, Identifiable {
    case today
    case history

    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: "今天"
        case .history: "活动记录"
        }
    }

    var icon: String {
        switch self {
        case .today: "sun.max.fill"
        case .history: "clock.arrow.circlepath"
        }
    }
}

private struct TimelineEntry: Identifiable {
    let id: String
    let title: String
    let detail: String
    let icon: String
    let color: Color
}

@MainActor
public struct MainWindowView: View {
    @StateObject private var store: AssistantStore
    @State private var selectedItem: SidebarItem = .today
    @State private var showingSettings = false

    public init(store: AssistantStore = AssistantStore()) {
        _store = StateObject(wrappedValue: store)
    }

    public var body: some View {
        NavigationSplitView {
            SidebarView(selection: $selectedItem) {
                showingSettings = true
            }
        } detail: {
            switch selectedItem {
            case .today:
                DashboardView(store: store)
            case .history:
                HistoryView(store: store)
            }
        }
        .navigationSplitViewStyle(.balanced)
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
    }
}

@MainActor
private struct SidebarView: View {
    @Binding var selection: SidebarItem
    let onSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.anotherAccentGradient)
                    Image(systemName: "sparkles")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 34, height: 34)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Another You")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                    Text("主动式个人助手")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 22)
            .padding(.bottom, 28)

            VStack(alignment: .leading, spacing: 5) {
                ForEach(SidebarItem.allCases) { item in
                    Button {
                        selection = item
                    } label: {
                        Label(item.title, systemImage: item.icon)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(selection == item ? Color.anotherInk : .secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 9)
                            .background {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(selection == item ? Color.anotherAccent.opacity(0.12) : .clear)
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 11)

            Spacer()

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(Color.anotherGreen)
                        .frame(width: 7, height: 7)
                    Text("本地 Agent 在线")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }

                Button(action: onSettings) {
                    Label("设置", systemImage: "slider.horizontal.3")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 22)
        }
        .frame(minWidth: 210, idealWidth: 228, maxWidth: 250)
        .background(Color.anotherSidebar)
    }
}

@MainActor
private struct DashboardView: View {
    @ObservedObject var store: AssistantStore

    private var timelineEntries: [TimelineEntry] {
        var entries = [
            TimelineEntry(
                id: "scan",
                title: "完成今日环境扫描",
                detail: "刚刚 · 日程、专注和备忘录已同步到本地",
                icon: "checkmark.shield.fill",
                color: .anotherGreen
            )
        ]

        entries.append(contentsOf: store.cards.filter { $0.state != .dismissed }.prefix(3).map { card in
            TimelineEntry(
                id: card.id.uuidString,
                title: card.title,
                detail: card.state == .pending ? "等待你的决定" : card.state.label,
                icon: card.kind.icon,
                color: card.kind.tint
            )
        })
        return entries
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HeroHeader(store: store)

                HStack(spacing: 12) {
                    MetricTile(
                        title: "今日建议",
                        value: "\(store.cards.count)",
                        caption: "已为你筛选",
                        icon: "sparkles",
                        color: .anotherAccent
                    )
                    MetricTile(
                        title: "已完成",
                        value: "\(store.completedCount)",
                        caption: store.completedCount == 0 ? "从第一步开始" : "节奏保持得很好",
                        icon: "checkmark",
                        color: .anotherGreen
                    )
                    MetricTile(
                        title: "下一次介入",
                        value: nextDueText,
                        caption: "只在需要时出现",
                        icon: "bell.badge",
                        color: .anotherOrange
                    )
                }

                VStack(alignment: .leading, spacing: 14) {
                    SectionHeading(
                        title: "今天替你留意",
                        subtitle: "我会先理解上下文，再把建议交给你决定"
                    )

                    LazyVStack(spacing: 12) {
                        ForEach(store.cards) { card in
                            ProactiveCardView(card: card) { action in
                                store.apply(action, to: card)
                            }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 14) {
                    SectionHeading(
                        title: "活动时间线",
                        subtitle: "你的助手最近做了什么"
                    )
                    ActivityTimeline(entries: timelineEntries)
                }
            }
            .frame(maxWidth: 920, alignment: .leading)
            .padding(.horizontal, 34)
            .padding(.vertical, 30)
        }
        .background(Color.anotherCanvas)
    }

    private var nextDueText: String {
        guard let nextDate = store.nextDueDate else { return "—" }
        let minutes = max(1, Int(nextDate.timeIntervalSinceNow / 60))
        return minutes < 60 ? "\(minutes) 分钟" : "\(minutes / 60) 小时"
    }
}

@MainActor
private struct HeroHeader: View {
    @ObservedObject var store: AssistantStore

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(greeting)
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.anotherInk)
                    Text("今天的节奏，我先替你照看着。")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.anotherInk.opacity(0.68))
                }

                Spacer()

                Button {
                    store.refresh()
                } label: {
                    Label("刷新建议", systemImage: "arrow.clockwise")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.anotherInk)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 9)
                        .background(.white.opacity(0.72), in: Capsule())
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 9) {
                Circle()
                    .fill(Color.anotherGreen)
                    .frame(width: 8, height: 8)
                Text(store.statusMessage)
                    .font(.system(size: 12, weight: .medium))
                Text("·")
                    .foregroundStyle(.secondary)
                Text("上次更新 \(store.lastUpdated.formatted(date: .omitted, time: .shortened))")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(Color.anotherInk.opacity(0.72))
        }
        .padding(26)
        .background {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(Color.anotherHeroGradient)
        }
        .overlay(alignment: .topTrailing) {
            Circle()
                .fill(.white.opacity(0.22))
                .frame(width: 130, height: 130)
                .blur(radius: 2)
                .offset(x: 35, y: -42)
                .allowsHitTesting(false)
        }
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12: return "早上好，今天想先做什么？"
        case 12..<18: return "下午好，给自己留一点空间。"
        default: return "晚上好，今天辛苦了。"
        }
    }
}

@MainActor
private struct MetricTile: View {
    let title: String
    let value: String
    let caption: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(color)
                    .frame(width: 26, height: 26)
                    .background(color.opacity(0.12), in: Circle())
                Spacer()
            }
            Text(value)
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .foregroundStyle(Color.anotherInk)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                Text(caption)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 124, alignment: .leading)
        .padding(16)
        .background(.white.opacity(0.76), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.black.opacity(0.035), lineWidth: 1)
        }
    }
}

@MainActor
private struct SectionHeading: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 19, weight: .bold, design: .rounded))
                .foregroundStyle(Color.anotherInk)
            Text(subtitle)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }
}

@MainActor
private struct ProactiveCardView: View {
    let card: ProactiveCard
    let onAction: (CardAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            HStack(alignment: .top, spacing: 13) {
                Image(systemName: card.kind.icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(card.kind.tint)
                    .frame(width: 34, height: 34)
                    .background(card.kind.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 11, style: .continuous))

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(card.kind.label)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(card.kind.tint)
                        Text("·")
                            .foregroundStyle(.tertiary)
                        Text(card.priority.label)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    Text(card.title)
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.anotherInk)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(card.detail)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)
                StateBadge(state: card.state)
            }

            VStack(alignment: .leading, spacing: 7) {
                Label(card.suggestion, systemImage: "wand.and.stars")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.anotherInk.opacity(0.82))
                Text(card.rationale)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.anotherCanvas, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            if card.state == .pending {
                HStack(spacing: 8) {
                    ActionButton(action: .execute, prominent: true, onAction: onAction)
                    ActionButton(action: .later, onAction: onAction)
                    ActionButton(action: .ignore, onAction: onAction)
                    Spacer()
                    Label(card.dueDate.formatted(date: .omitted, time: .shortened), systemImage: "clock")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            } else {
                Text(stateMessage)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(card.state.tint)
            }
        }
        .padding(18)
        .background(.white.opacity(0.82), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(card.state == .pending ? Color.black.opacity(0.045) : card.state.tint.opacity(0.28), lineWidth: 1)
        }
    }

    private var stateMessage: String {
        switch card.state {
        case .scheduled: "已放入稍后提醒，我会在合适的时间再出现。"
        case .done: "已完成，今天又向前走了一步。"
        case .dismissed: "已忽略，之后可以在活动记录中查看。"
        case .pending: ""
        }
    }
}

@MainActor
private struct ActionButton: View {
    let action: CardAction
    var prominent = false
    let onAction: (CardAction) -> Void

    var body: some View {
        Button {
            onAction(action)
        } label: {
            Label(action.label, systemImage: action.icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(prominent ? .white : Color.anotherInk.opacity(0.75))
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
                .background {
                    if prominent {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(Color.anotherInk)
                    } else {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(Color.anotherCanvas)
                    }
                }
        }
        .buttonStyle(.plain)
    }
}

@MainActor
private struct StateBadge: View {
    let state: CardState

    var body: some View {
        Text(state.label)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(state.tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(state.tint.opacity(0.1), in: Capsule())
    }
}

@MainActor
private struct ActivityTimeline: View {
    let entries: [TimelineEntry]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                HStack(alignment: .top, spacing: 12) {
                    VStack(spacing: 0) {
                        Image(systemName: entry.icon)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(entry.color)
                            .frame(width: 26, height: 26)
                            .background(entry.color.opacity(0.12), in: Circle())
                        if index < entries.count - 1 {
                            Rectangle()
                                .fill(Color.black.opacity(0.08))
                                .frame(width: 1, height: 30)
                        }
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.title)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.anotherInk)
                        Text(entry.detail)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 3)
                    Spacer()
                }
            }
        }
        .padding(18)
        .background(.white.opacity(0.7), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

@MainActor
private struct HistoryView: View {
    @ObservedObject var store: AssistantStore

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SectionHeading(title: "活动记录", subtitle: "每一次介入都由你掌控")
            ForEach(store.cards.filter { $0.state != .pending }) { card in
                HStack(spacing: 12) {
                    Image(systemName: card.kind.icon)
                        .foregroundStyle(card.kind.tint)
                        .frame(width: 28, height: 28)
                        .background(card.kind.tint.opacity(0.12), in: Circle())
                    VStack(alignment: .leading, spacing: 4) {
                        Text(card.title)
                            .font(.system(size: 13, weight: .semibold))
                        Text(card.state.label)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(14)
                .background(.white.opacity(0.8), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            if store.cards.allSatisfy({ $0.state == .pending }) {
                Text("还没有活动记录，决定一条建议后它会出现在这里。")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 12)
            }
            Spacer()
        }
        .frame(maxWidth: 720, alignment: .leading)
        .padding(34)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.anotherCanvas)
    }
}

public struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var proactiveEnabled = true
    @State private var quietHoursEnabled = true
    @State private var localOnly = true

    public init() {}

    public var body: some View {
        Form {
            Section {
                Toggle("允许主动建议", isOn: $proactiveEnabled)
                Toggle("遵守安静时段", isOn: $quietHoursEnabled)
            } header: {
                Text("主动性")
            } footer: {
                Text("助手会根据上下文选择少量真正有帮助的时机。")
            }

            Section {
                Toggle("仅使用本地 Agent", isOn: $localOnly)
                Label("数据留在这台 Mac 上", systemImage: "lock.shield.fill")
                    .foregroundStyle(Color.anotherGreen)
            } header: {
                Text("隐私")
            } footer: {
                Text("当前版本使用本地 mock 数据，AgentClient 可替换为私有化实现。")
            }

            Section("关于") {
                LabeledContent("版本", value: "0.1 本地预览")
                LabeledContent("运行状态", value: "Agent 已就绪")
            }
        }
        .formStyle(.grouped)
        .frame(width: 470, height: 420)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("完成") {
                    dismiss()
                }
            }
        }
    }
}

private extension CardKind {
    var tint: Color {
        switch self {
        case .focus: .anotherAccent
        case .wellbeing: .anotherGreen
        case .idea: .anotherPurple
        case .reminder: .anotherOrange
        }
    }
}

private extension CardState {
    var tint: Color {
        switch self {
        case .pending: .anotherAccent
        case .scheduled: .anotherOrange
        case .done: .anotherGreen
        case .dismissed: .secondary
        }
    }
}

private extension Color {
    static let anotherInk = Color(red: 0.10, green: 0.12, blue: 0.17)
    static let anotherCanvas = Color(red: 0.965, green: 0.958, blue: 0.945)
    static let anotherSidebar = Color(red: 0.985, green: 0.981, blue: 0.968)
    static let anotherAccent = Color(red: 0.31, green: 0.29, blue: 0.85)
    static let anotherGreen = Color(red: 0.14, green: 0.55, blue: 0.40)
    static let anotherOrange = Color(red: 0.90, green: 0.46, blue: 0.19)
    static let anotherPurple = Color(red: 0.65, green: 0.32, blue: 0.77)
    static let anotherAccentGradient = LinearGradient(
        colors: [Color(red: 0.39, green: 0.35, blue: 0.95), Color(red: 0.25, green: 0.57, blue: 0.85)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    static let anotherHeroGradient = LinearGradient(
        colors: [Color(red: 0.88, green: 0.91, blue: 1.0), Color(red: 0.93, green: 0.89, blue: 0.99)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}
