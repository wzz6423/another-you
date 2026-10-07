import ImageIO
import SwiftUI

@MainActor
struct ConversationView: View {
    @Environment(\.locale) private var interfaceLocale
    @ObservedObject var store: AssistantStore
    var focusRequest: UUID? = nil
    var onSettings: (() -> Void)? = nil
    var onBack: (() -> Void)? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                if let onBack {
                    Button(AppLocalization.text("返回会话看板"), systemImage: "chevron.backward", action: onBack)
                        .labelStyle(.iconOnly).help(AppLocalization.text("返回会话看板"))
                        .disabled(!store.pendingConversationActions.isEmpty)
                }
                Text(store.sessions.first { $0.id == store.selectedConversationID }?.title ?? AppLocalization.text("会话"))
                    .font(.system(size: 22, weight: .semibold, design: .rounded)).lineLimit(1)
                Spacer()
                ConversationExportButton(store: store)
                Button(AppLocalization.text("创建分支"), systemImage: "arrow.triangle.branch") { store.forkConversation() }
                    .disabled(!store.canForkConversation)
            }
            if let origin = store.sessions.first(where: { $0.id == store.selectedConversationID })?.forkedFrom {
                HStack {
                    Text(AppLocalization.text("分支会话")).font(.caption).foregroundStyle(.secondary)
                    if store.sessions.contains(where: { $0.id == origin.conversationID }) {
                        Button(AppLocalization.text("查看来源会话")) { store.selectConversation(origin.conversationID) }
                            .font(.caption).disabled(!store.pendingConversationActions.isEmpty)
                    }
                }
            }
            if store.isLoadingConversation { ProgressView(AppLocalization.text("正在读取会话…")).controlSize(.small) }
            if let error = store.conversationActionError {
                HStack {
                    Text(error).font(.caption).foregroundStyle(.red)
                    if let id = store.selectedConversationID {
                        Button(AppLocalization.text("重试")) { store.selectConversation(id) }
                            .disabled(!store.pendingConversationActions.isEmpty)
                    }
                }
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if store.conversation.isEmpty {
                            Text(AppLocalization.text("写下想梳理的一件事，我们一起想想。"))
                                .font(.system(size: 13)).foregroundStyle(.secondary).padding(.vertical, 24)
                        }
                        ForEach(store.conversation) { message in
                            VStack(alignment: .leading, spacing: 6) {
                                ConversationMessageRow(message: message).equatable()
                                Button(AppLocalization.text("从此处分支"), systemImage: "arrow.triangle.branch") {
                                    store.forkConversation(through: message.id)
                                }
                                .font(.caption).buttonStyle(.borderless).foregroundStyle(.secondary)
                                .disabled(!store.canForkConversation || message.isPending)
                            }
                                .id(message.id)
                                .transition(.opacity)
                        }
                    }
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: store.conversation.count)
                }
                .onChange(of: store.conversation) { _, messages in
                    if let last = messages.last {
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
            ConversationModelNotice(store: store, onSettings: onSettings)
            if store.selectedConversationArchived {
                HStack {
                    Text(AppLocalization.text("已归档会话")).font(.caption).foregroundStyle(.secondary)
                    Button(AppLocalization.text("恢复会话")) {
                        if let id = store.selectedConversationID { store.manageConversation(id, action: "unarchive") }
                    }.disabled(!store.isConnected || !store.pendingConversationActions.isEmpty)
                }
            } else { ConversationComposer(store: store, focusRequest: focusRequest) }
        }
        .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

@MainActor
struct ConversationModelNotice: View {
    @Environment(\.locale) private var interfaceLocale
    @ObservedObject var store: AssistantStore
    var onSettings: (() -> Void)? = nil
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if !store.isConnected || !store.modelConfigured {
            HStack {
                Text(store.isConnected ? AppLocalization.text("请在设置中选择模型并配置账户") : store.connection.label)
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(AppLocalization.text("模型设置")) {
                    if let onSettings { onSettings() } else { openWindow(id: "settings") }
                }
                if !store.isConnected {
                    Button(AppLocalization.text("重新连接")) { store.refresh() }.disabled(store.connection == .starting || store.isRestarting)
                }
            }.padding(.bottom, 10)
        }
    }
}

@MainActor
struct ConversationComposer: View {
    @Environment(\.locale) private var interfaceLocale
    @ObservedObject var store: AssistantStore
    @ObservedObject private var draft: InputDraft
    @ObservedObject private var desktop: DesktopSession
    @ObservedObject private var updates: UpdateController
    let focusRequest: UUID?
    @FocusState private var inputFocused: Bool
    private var prompt: String { draft.text }

    init(store: AssistantStore, focusRequest: UUID?) {
        self.store = store
        self.focusRequest = focusRequest
        draft = store.draft(for: .conversation)
        desktop = store.desktop
        updates = store.updates
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 10) {
            CaptureAttachmentsView(session: desktop)
            if let activity = desktop.activity { Text(activity).font(.caption).foregroundStyle(.secondary) }
            TextField(AppLocalization.text("写下想梳理的一件事…"), text: Binding(get: { prompt }, set: { store.setInputDraft($0, for: .conversation) }), axis: .vertical)
                .lineLimit(3...8).textFieldStyle(.plain).font(.system(size: 13))
                .focused($inputFocused)
                .disabled(updates.isInstalling)
            HStack(spacing: 12) {
                if store.selectedConversationHasPendingPrompt {
                    Button(AppLocalization.text("停止"), systemImage: "stop.fill") { store.stopCurrentTask() }
                        .appShortcut(.stop)
                }
                Spacer()
                Toggle(AppLocalization.text("允许前台控制"), isOn: $desktop.allowForeground)
                    .toggleStyle(.checkbox).font(.caption)
                    .help(AppLocalization.text("开启后，电脑操作可能移动鼠标、输入文字或切换应用。默认使用后台操作。"))
                Button(store.selectedConversationHasPendingPrompt ? AppLocalization.text("正在生成") : AppLocalization.text("发送"), systemImage: "arrow.up") {
                    if store.ask(prompt) { store.setInputDraft("", for: .conversation); inputFocused = true }
                }
                .buttonStyle(.borderedProminent).tint(.blue).controlSize(.small)
                .appShortcut(.sendMessage)
                .disabled((prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && desktop.attachments.isEmpty) || !store.isConnected || !store.modelConfigured || store.selectedConversationHasPendingPrompt || store.isLoadingConversation || updates.isInstalling || !store.pendingConversationActions.isEmpty || (store.selectedConversationID != nil && store.conversationActionError != nil))
            }
        }
        .padding(16).background(.background, in: RoundedRectangle(cornerRadius: 16))
        .onAppear { inputFocused = true }
        .onChange(of: focusRequest) { _, _ in inputFocused = true }
    }
}

@MainActor
private struct ConversationMessageRow: View, Equatable {
    @Environment(\.locale) private var interfaceLocale
    let message: ConversationMessage
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.message == rhs.message }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !message.attachments.isEmpty {
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(message.attachments) { attachment in
                            if let image = ConversationImageCache.shared.image(for: attachment) {
                                Image(nsImage: image).resizable().scaledToFit().frame(width: 140, height: 88)
                                    .accessibilityLabel(AppLocalization.text("已发送的截图"))
                            }
                        }
                    }
                }
            }
            Text(message.prompt).font(.system(size: 13, weight: .medium)).textSelection(.enabled)
            if let response = message.response {
                MarkdownText(response).transition(.opacity)
            } else if let error = message.error {
                Text(AppLocalization.message(error)).font(.system(size: 12)).foregroundStyle(.red).textSelection(.enabled).transition(.opacity)
            } else {
                ProgressView(AppLocalization.text("正在处理…")).controlSize(.small).transition(.opacity)
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 14))
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: message.isPending)
    }
}

@MainActor
final class ConversationImageCache {
    static let shared = ConversationImageCache()
    private let images = NSCache<NSUUID, NSImage>()

    init() {
        images.countLimit = 64
        images.totalCostLimit = 16 * 1024 * 1024
    }

    func image(for attachment: ScreenAttachment) -> NSImage? {
        let key = attachment.id as NSUUID
        if let image = images.object(forKey: key) { return image }
        guard let source = CGImageSourceCreateWithData(attachment.capture.imageData as CFData, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 280,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        let representation = NSBitmapImageRep(cgImage: thumbnail)
        representation.size = NSSize(width: CGFloat(thumbnail.width) / 2, height: CGFloat(thumbnail.height) / 2)
        let image = NSImage(size: representation.size)
        image.addRepresentation(representation)
        images.setObject(image, forKey: key, cost: thumbnail.width * thumbnail.height * 4)
        return image
    }
}
