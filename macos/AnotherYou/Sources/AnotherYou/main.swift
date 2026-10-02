import AppKit
import SwiftUI
import AnotherYouCore

@MainActor
final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    var store: AssistantStore?
    let quickChat = QuickChatController()
    var shortcuts: GlobalShortcutCoordinator?
    private var isTerminating = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isTerminating else { return .terminateNow }
        isTerminating = true
        shortcuts?.stop()
        Task {
            await store?.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@main
struct AnotherYouApp: App {
    @NSApplicationDelegateAdaptor(ApplicationDelegate.self) private var delegate
    @StateObject private var store = AssistantStore()
    @ObservedObject private var languages = AppLanguageStore.shared
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        WindowGroup(id: "main") {
            MainWindowView(store: store)
                .environment(\.locale, languages.locale)
                .environment(\.layoutDirection, languages.layoutDirection)
                .task {
                    delegate.store = store
                    delegate.quickChat.configure(store: store, onSettings: showSettings)
                    if delegate.shortcuts == nil {
                        let coordinator = GlobalShortcutCoordinator { action in
                            switch action {
                            case .quickChat:
                                store.desktop.rememberCurrentApplication()
                                delegate.quickChat.show()
                            case .captureRegion, .captureWindow, .captureScreen:
                                let mode: DesktopCaptureMode = action == .captureRegion ? .region : action == .captureWindow ? .window : .screen
                                store.desktop.capture(mode) { delegate.quickChat.show() }
                            default: break
                            }
                        }
                        delegate.shortcuts = coordinator
                        coordinator.start()
                    }
                }
        }
        .defaultSize(width: 1040, height: 780)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesButton(updates: store.updates)
            }
            CommandGroup(after: .newItem) {
                Button(AppLocalization.text("快速会话")) { delegate.quickChat.show() }
            }
            CommandGroup(replacing: .appSettings) {
                Button(AppLocalization.text("设置…"), action: showSettings).appShortcut(.settings)
            }
            CommandGroup(replacing: .appTermination) {
                Button(AppLocalization.text("退出 Another You")) { NSApplication.shared.terminate(nil) }.appShortcut(.quit)
            }
        }

        Window(AppLocalization.text("设置"), id: "settings") {
            SettingsView(store: store)
                .environment(\.locale, languages.locale)
                .environment(\.layoutDirection, languages.layoutDirection)
        }
        .defaultSize(width: 720, height: 600)
        .windowResizability(.contentMinSize)

        MenuBarExtra("Another You", systemImage: "circle.lefthalf.filled") {
            Text(store.paused && store.isConnected ? AppLocalization.text("主动建议已暂停") : store.connection.label)
            if store.pendingCount > 0 { Text(AppLocalization.text("%d 条建议等待决定", store.pendingCount)) }
            Divider()
            Button(AppLocalization.text("打开 Another You")) {
                openWindow(id: "main")
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
            Button(AppLocalization.text("快速会话")) { store.desktop.rememberCurrentApplication(); delegate.quickChat.show() }
            Button(AppLocalization.text("截取区域")) { store.desktop.capture(.region) { delegate.quickChat.show() } }
            Button(store.paused ? AppLocalization.text("恢复主动建议") : AppLocalization.text("暂停主动建议")) { store.togglePause() }
                .disabled(!store.isConnected || store.isChangingPause)
            Button(AppLocalization.text("刷新连接")) { store.refresh() }.disabled(store.connection == .starting || store.isRestarting)
            Button(AppLocalization.text("设置…"), action: showSettings)
            CheckForUpdatesButton(updates: store.updates)
            Divider()
            Button(AppLocalization.text("退出 Another You")) { NSApplication.shared.terminate(nil) }.appShortcut(.quit)
        }
    }

    private func showSettings() {
        openWindow(id: "settings")
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}

private struct CheckForUpdatesButton: View {
    @ObservedObject private var languages = AppLanguageStore.shared
    @ObservedObject var updates: UpdateController

    var body: some View {
        Button(AppLocalization.text("检查更新…"), action: updates.checkForUpdates).disabled(!updates.canCheck)
    }
}
