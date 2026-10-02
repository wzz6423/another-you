import SwiftUI

private struct BoardEntry: Identifiable {
    var session: ConversationSession?
    var proposal: ProactiveCard?
    var id: String { session?.id ?? proposal!.id }
    var title: String { session?.title ?? proposal!.title }
    var appName: String { session?.appName ?? proposal?.appName ?? AppLocalization.text("未关联应用") }
    var date: Date { session?.updatedAt ?? proposal!.createdAt }
    var completed: Bool { session?.state == "completed" || proposal?.state == .completed || proposal?.state == .ignored }
    var running: Bool { session?.state == "running" || proposal?.state == .running }
    var archived: Bool { session?.archived ?? proposal!.archived }
    var stateLabel: String {
        if let proposal { return proposal.state.label }
        return AppLocalization.text(session?.state == "running" ? "进行中" : session?.state == "completed" ? "已完成" : "失败")
    }
}

@MainActor
struct ConversationBoardView: View {
    @Environment(\.locale) private var interfaceLocale
    @ObservedObject var store: AssistantStore
    var archived = false
    var onOpen: (() -> Void)? = nil
    @AppStorage("AnotherYou.Board.GroupByApplication") private var groupByApplication = false
    @State private var selectedProposal: ProactiveCard?
    @State private var previewSession = false

    private var entries: [BoardEntry] {
        (store.sessions.map { BoardEntry(session: $0) } + store.cards.map { BoardEntry(proposal: $0) })
            .filter { $0.archived == archived }.sorted { $0.date > $1.date }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(AppLocalization.text(archived ? "已归档会话" : "会话看板")).font(.headline)
                Spacer()
                Toggle(AppLocalization.text("按应用分组"), isOn: $groupByApplication).toggleStyle(.checkbox).font(.caption)
            }
            if let error = store.conversationActionError { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            if archived {
                entryList(entries)
            } else {
                HStack(alignment: .top, spacing: 14) {
                    column(AppLocalization.text("进行中"), entries: entries.filter { !$0.completed })
                    column(AppLocalization.text("已完成"), entries: entries.filter(\.completed))
                }
            }
        }
        .sheet(item: $selectedProposal) { proposal in
            ScrollView {
                if let current = store.cards.first(where: { $0.id == proposal.id }) {
                    ProactiveCardView(card: current, busy: store.pendingActions.contains(current.id), connected: store.isConnected && !current.archived, modelConfigured: store.modelConfigured) { store.apply($0, to: current) }
                }
            }.padding(20).frame(minWidth: 480, idealWidth: 580, minHeight: 300)
                .safeAreaInset(edge: .top) {
                    HStack { Spacer(); Button(AppLocalization.text("关闭")) { selectedProposal = nil }.keyboardShortcut(.cancelAction) }.padding(12)
                }
        }
        .sheet(isPresented: $previewSession) {
            ConversationView(store: store).frame(width: 620, height: 560)
                .safeAreaInset(edge: .top) {
                    HStack { Spacer(); Button(AppLocalization.text("关闭")) { previewSession = false }.keyboardShortcut(.cancelAction) }.padding(12)
                }
        }
    }

    private func column(_ title: String, entries: [BoardEntry]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title).font(.subheadline.bold())
                Text(AppLocalization.number(entries.count)).font(.caption).foregroundStyle(.secondary)
            }
            entryList(entries)
        }.frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func entryList(_ entries: [BoardEntry]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if entries.isEmpty {
                Text(AppLocalization.text(archived ? "暂无已归档会话" : "暂无会话"))
                    .font(.caption).foregroundStyle(.secondary).padding(20).frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(groupByApplication ? Array(Set(entries.map(\.appName))).sorted() : [""], id: \.self) { group in
                if groupByApplication { Text(group).font(.caption.bold()).foregroundStyle(.secondary).padding(.top, 4) }
                ForEach(entries.filter { !groupByApplication || $0.appName == group }) { entry in
                    entryRow(entry)
                }
            }
        }
    }

    private func entryRow(_ entry: BoardEntry) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top) {
                Button {
                    if let proposal = entry.proposal { selectedProposal = proposal }
                    else {
                        store.selectConversation(entry.id)
                        if let onOpen { onOpen() } else { previewSession = true }
                    }
                } label: {
                    Text(entry.title).font(.subheadline.weight(.medium)).lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain).disabled(entry.session != nil && store.hasPendingPrompt)
                Menu {
                    Button(AppLocalization.text(entry.archived ? "恢复会话" : "归档")) {
                        store.manageConversation(entry.id, action: entry.archived ? "unarchive" : "archive")
                    }
                    Button(AppLocalization.text("删除"), role: .destructive) { store.manageConversation(entry.id, action: "delete") }
                } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).fixedSize()
                    .disabled(entry.running || !store.isConnected || store.pendingConversationActions.contains(entry.id))
                    .accessibilityLabel(AppLocalization.text("会话操作"))
            }
            HStack(spacing: 6) {
                if entry.running { ProgressView().controlSize(.mini) }
                Text(entry.stateLabel).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(AppLocalization.date(entry.date, includeDate: false)).font(.caption2).foregroundStyle(.tertiary)
            }
            if !groupByApplication { Text(entry.appName).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
        }
        .padding(14).background(.background, in: RoundedRectangle(cornerRadius: 12))
    }
}
