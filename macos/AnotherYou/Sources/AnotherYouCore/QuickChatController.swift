import AppKit
import Combine
import SwiftUI

@MainActor
public final class QuickChatController: ObservableObject {
    private static let compactHeight: CGFloat = 72
    @Published private var focusRequest = UUID()
    private var panel: NSPanel?
    private weak var store: AssistantStore?
    private var attachmentObservation: AnyCancellable?
    @Published private(set) var desktopSnapshot: [String: JSONValue]?
    private(set) var conversationID: String?
    private var snapshotTask: Task<[String: JSONValue], Never>?
    private var showTask: Task<Void, Never>?

    public init() {}

    public func configure(store: AssistantStore) {
        guard panel == nil else { return }
        let panel = InputPanel(contentRect: NSRect(x: 0, y: 0, width: 580, height: Self.compactHeight),
                               styleMask: [.borderless], backing: .buffered, defer: false)
        panel.title = AppLocalization.text("Another You · 快速会话")
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.onClose = { [weak self] in self?.close() }
        panel.contentView = NSHostingView(rootView: QuickChatContent(controller: self, store: store))
        self.panel = panel
        self.store = store
        attachmentObservation = store.desktop.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.resizeForAttachments() }
        }
    }

    public func show() {
        guard let panel, let store else { return }
        close()
        panel.title = AppLocalization.text("Another You · 快速会话")
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let screen {
            let frame = screen.frame
            let width = min(580, frame.width - 32)
            panel.setFrame(NSRect(x: frame.midX - width / 2,
                                  y: frame.minY + frame.height * 0.2 - Self.compactHeight / 2,
                                  width: width, height: Self.compactHeight), display: true)
        }
        prepareInvocation(using: store.desktop) { [weak self] in
            guard let self else { return }
            resizeForAttachments()
            panel.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            focusRequest = UUID()
        }
    }

    func prepareInvocation(using desktop: DesktopSession, present: @escaping @MainActor () -> Void) {
        showTask?.cancel()
        snapshotTask?.cancel()
        desktopSnapshot = nil
        conversationID = UUID().uuidString
        // 显示浮窗前保存文字和图片，模型读取时不再依赖用户后来的前台应用。
        let capture = desktop.prepareInvocationSnapshot()
        snapshotTask = capture
        showTask = Task { [weak self] in
            let snapshot = await capture.value
            guard !Task.isCancelled, !capture.isCancelled, let self else { return }
            desktopSnapshot = snapshot
            snapshotTask = nil
            showTask = nil
            present()
        }
    }

    func close() {
        showTask?.cancel()
        snapshotTask?.cancel()
        showTask = nil
        snapshotTask = nil
        desktopSnapshot = nil
        conversationID = nil
        panel?.orderOut(nil)
    }

    private func resizeForAttachments() {
        guard let panel, let desktop = store?.desktop else { return }
        let height = Self.compactHeight + (desktop.attachments.isEmpty && desktop.error == nil ? 0 : 160)
        var frame = panel.frame
        frame.size.height = height
        panel.setFrame(frame, display: true)
    }

    private final class InputPanel: NSPanel {
        var onClose: (() -> Void)?
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }

        override func sendEvent(_ event: NSEvent) {
            // 在文本编辑器或输入法消费 Esc 之前关闭浮窗。
            if event.type == .keyDown, ShortcutAction.closeQuickChat.defaultHotKey.matches(event) {
                onClose?()
                return
            }
            super.sendEvent(event)
        }
    }

    private struct QuickChatContent: View {
        @Environment(\.locale) private var interfaceLocale
        @ObservedObject var controller: QuickChatController
        @ObservedObject private var languages = AppLanguageStore.shared
        @ObservedObject var store: AssistantStore
        @ObservedObject private var draft: InputDraft
        @ObservedObject private var desktop: DesktopSession
        @ObservedObject private var updates: UpdateController
        @ObservedObject private var modelSettings: ModelConfigurationSession
        @ObservedObject private var localModelSettings: LocalModelSettingsSession
        private var prompt: String { draft.text }
        @FocusState private var inputFocused: Bool

        init(controller: QuickChatController, store: AssistantStore) {
            self.controller = controller
            self.store = store
            draft = store.draft(for: .quickChat)
            desktop = store.desktop
            updates = store.updates
            modelSettings = store.modelSettings
            localModelSettings = store.localModelSettings
        }

        var body: some View {
            VStack(spacing: 10) {
                if !desktop.attachments.isEmpty || desktop.error != nil {
                    CaptureAttachmentsView(session: desktop)
                        .padding(12).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
                glassInput
            }
                .padding(14)
                .environment(\.locale, languages.locale)
                .environment(\.layoutDirection, languages.layoutDirection)
                .onAppear { inputFocused = true }
                .onChange(of: controller.focusRequest) { _, _ in inputFocused = true }
        }

        private var glassInput: some View {
            input
                .background {
                    ZStack {
                        if #available(macOS 26.0, *) {
                            LiquidGlassInputBackground()
                        } else {
                            FrostedInputBackground()
                        }
                        LinearGradient(stops: [
                            .init(color: .black.opacity(0.82), location: 0),
                            .init(color: .black.opacity(0.50), location: 0.35),
                            .init(color: .black.opacity(0.14), location: 0.75),
                            .init(color: .clear, location: 1)
                        ], startPoint: .top, endPoint: .bottom)
                    }
                    .clipShape(Capsule())
                    .allowsHitTesting(false)
                }
                .overlay(Capsule().strokeBorder(.white.opacity(0.2), lineWidth: 0.5).allowsHitTesting(false))
                .environment(\.colorScheme, .dark)
        }

        private var canSend: Bool {
            store.isConnected && store.modelConfigured
                && controller.desktopSnapshot != nil
                && !updates.isInstalling && !modelSettings.isBusy && !localModelSettings.isBusy
                && store.pendingConversationActions.isEmpty
                && (!prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !desktop.attachments.isEmpty)
        }

        private var input: some View {
            HStack(spacing: 12) {
                TextField(AppLocalization.text("有什么想一起做的？"),
                          text: Binding(get: { prompt }, set: { store.setInputDraft($0, for: .quickChat) }),
                          prompt: Text(AppLocalization.text("有什么想一起做的？")).foregroundStyle(.white.opacity(0.65)))
                    .textFieldStyle(.plain).font(.system(size: 14))
                    .foregroundStyle(.white)
                    .focused($inputFocused)
                    .onSubmit(send)
                    .disabled(updates.isInstalling)
                HStack(spacing: 8) {
                    Button { controller.close() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 28, height: 28)
                            .background(.red, in: Circle())
                    }
                    .appShortcut(.closeQuickChat).help(AppLocalization.text("关闭快速会话"))
                    .accessibilityLabel(AppLocalization.text("关闭快速会话"))
                    Button(action: send) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 28, height: 28)
                            .background(.blue, in: Circle())
                    }
                    .appShortcut(.sendMessage).help(AppLocalization.text("发送"))
                    .accessibilityLabel(AppLocalization.text("发送"))
                    .disabled(!canSend)
                    .opacity(canSend ? 1 : 0.45)
                }
            }
            .buttonStyle(.plain)
            .padding(.leading, 18)
            .padding(.trailing, 10)
            .frame(height: 44)
        }

        private func send() {
            guard let snapshot = controller.desktopSnapshot, let id = controller.conversationID else { return }
            if store.ask(prompt, startsNewConversation: true, newConversationID: id, desktopSnapshot: snapshot) {
                store.setInputDraft("", for: .quickChat)
                controller.close()
            }
        }
    }
}

@available(macOS 26.0, *)
private struct LiquidGlassInputBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSGlassEffectView {
        let view = NSGlassEffectView()
        // 透明内容层触发完整玻璃合成，避免只渲染边缘。
        let host = NSView(frame: view.bounds)
        host.autoresizingMask = [.width, .height]
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.clear.cgColor
        view.contentView = host
        view.style = .clear
        view.tintColor = nil
        view.cornerRadius = 22
        view.appearance = NSAppearance(named: .darkAqua)
        return view
    }

    func updateNSView(_ view: NSGlassEffectView, context: Context) {}
}

private struct FrostedInputBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.appearance = NSAppearance(named: .darkAqua)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
