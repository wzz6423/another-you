import AppKit
import Combine
import SwiftUI

@MainActor
public final class QuickChatController: ObservableObject {
    @Published private var focusRequest = UUID()
    private var panel: NSPanel?
    private weak var store: AssistantStore?
    private var attachmentObservation: AnyCancellable?

    public init() {}

    public func configure(store: AssistantStore, onSettings: @escaping () -> Void) {
        guard panel == nil else { return }
        let panel = InputPanel(contentRect: NSRect(x: 0, y: 0, width: 580, height: 100),
                               styleMask: [.borderless], backing: .buffered, defer: false)
        panel.title = AppLocalization.text("Another You · 快速会话")
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: QuickChatContent(controller: self, store: store, onSettings: onSettings))
        self.panel = panel
        self.store = store
        attachmentObservation = store.desktop.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.resizeForAttachments() }
        }
    }

    public func show() {
        guard let panel else { return }
        panel.title = AppLocalization.text("Another You · 快速会话")
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let screen {
            let frame = screen.frame
            let width = min(580, frame.width - 32)
            panel.setFrame(NSRect(x: frame.midX - width / 2,
                                  y: frame.minY + frame.height * 0.2 - 50,
                                  width: width, height: 100), display: true)
        }
        resizeForAttachments()
        panel.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        focusRequest = UUID()
    }

    private func resizeForAttachments() {
        guard let panel, let desktop = store?.desktop else { return }
        let height: CGFloat = desktop.attachments.isEmpty && desktop.error == nil ? 100 : 260
        var frame = panel.frame
        frame.size.height = height
        panel.setFrame(frame, display: true)
    }

    private final class InputPanel: NSPanel {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
    }

    private struct QuickChatContent: View {
        @Environment(\.locale) private var interfaceLocale
        @ObservedObject var controller: QuickChatController
        @ObservedObject private var languages = AppLanguageStore.shared
        @ObservedObject var store: AssistantStore
        @ObservedObject private var draft: InputDraft
        @ObservedObject private var desktop: DesktopSession
        @ObservedObject private var updates: UpdateController
        let onSettings: () -> Void
        private var prompt: String { draft.text }
        @FocusState private var inputFocused: Bool

        init(controller: QuickChatController, store: AssistantStore, onSettings: @escaping () -> Void) {
            self.controller = controller
            self.store = store
            self.onSettings = onSettings
            draft = store.draft(for: .quickChat)
            desktop = store.desktop
            updates = store.updates
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
                .background {
                    Button(AppLocalization.text("关闭快速会话")) { controller.panel?.orderOut(nil) }
                        .appShortcut(.closeQuickChat).hidden()
                }
        }

        @ViewBuilder
        private var glassInput: some View {
            if #available(macOS 26.0, *) {
                input.background { LiquidGlassInputBackground().allowsHitTesting(false) }
                    .environment(\.colorScheme, .dark)
            } else {
                input.background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(.white.opacity(0.2), lineWidth: 0.5))
            }
        }

        private var input: some View {
            HStack(spacing: 12) {
                TextField(AppLocalization.text("有什么想一起做的？"), text: Binding(get: { prompt }, set: { store.setInputDraft($0, for: .quickChat) }))
                    .textFieldStyle(.plain).font(.system(size: 16))
                    .focused($inputFocused)
                    .onSubmit(send)
                    .disabled(updates.isInstalling)
                if store.hasPendingPrompt {
                    Button(action: store.stopCurrentTask) { Image(systemName: "stop.fill") }
                        .appShortcut(.stop).help(AppLocalization.text("停止当前任务"))
                        .accessibilityLabel(AppLocalization.text("停止当前任务"))
                } else if !store.modelConfigured || !store.isConnected {
                    Button { controller.panel?.orderOut(nil); onSettings() } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                    .help(AppLocalization.text("连接模型")).accessibilityLabel(AppLocalization.text("连接模型"))
                } else {
                    Button(action: send) { Image(systemName: "arrow.up").foregroundStyle(.blue) }
                        .appShortcut(.sendMessage).help(AppLocalization.text("发送"))
                        .accessibilityLabel(AppLocalization.text("发送"))
                        .disabled(updates.isInstalling || store.isLoadingConversation || (prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && desktop.attachments.isEmpty))
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 22)
            .frame(height: 64)
        }

        private func send() {
            if store.ask(prompt) {
                store.setInputDraft("", for: .quickChat)
                controller.panel?.orderOut(nil)
            }
        }
    }
}

@available(macOS 26.0, *)
private struct LiquidGlassInputBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSGlassEffectView {
        let view = NSGlassEffectView()
        // 与 Zisla 一致：透明内容层让原生玻璃启用完整合成，避免只显示边缘。
        let host = NSView(frame: view.bounds)
        host.autoresizingMask = [.width, .height]
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.clear.cgColor
        view.contentView = host
        configure(view)
        return view
    }

    func updateNSView(_ view: NSGlassEffectView, context: Context) {
        configure(view)
    }

    private func configure(_ view: NSGlassEffectView) {
        view.style = .clear
        view.tintColor = nil
        view.cornerRadius = 32
    }
}
