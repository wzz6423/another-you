import SwiftUI

@MainActor
struct ConversationWorkspaceView: View {
    @Environment(\.locale) private var interfaceLocale
    @ObservedObject var store: AssistantStore
    @ObservedObject private var shortcuts = ShortcutStore.shared

    var body: some View {
        if store.selectedConversationID != nil {
            ConversationView(store: store, onBack: store.newConversation)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(AppLocalization.text("会话")).font(.system(size: 22, weight: .semibold, design: .rounded))
                    Spacer()
                    Text(AppLocalization.text("%@ 快速呼起", shortcuts.label(for: .quickChat)))
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(.bottom, 24)
                ScrollView {
                    ConversationBoardView(store: store, includesArchived: true, onOpen: {})
                        .padding(.bottom, 24)
                }
                Divider().padding(.vertical, 24)
                Text(AppLocalization.text("新会话")).font(.headline).padding(.bottom, 12)
                ConversationModelNotice(store: store)
                ConversationComposer(store: store, focusRequest: nil)
            }
            .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }
}
