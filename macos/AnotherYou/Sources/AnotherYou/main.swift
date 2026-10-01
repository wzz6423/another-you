import AppKit
import SwiftUI
import AnotherYouCore

@MainActor
final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    var store: AssistantStore?
    private var isTerminating = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isTerminating else { return .terminateNow }
        isTerminating = true
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
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        WindowGroup(id: "main") {
            MainWindowView(store: store)
                .task { delegate.store = store }
        }
        .defaultSize(width: 1040, height: 780)
        .windowStyle(.hiddenTitleBar)

        Settings { SettingsView(store: store) }

        MenuBarExtra("Another You", systemImage: "circle.lefthalf.filled") {
            Text(store.paused && store.isConnected ? "主动建议已暂停" : store.connection.label)
            if store.pendingCount > 0 { Text("\(store.pendingCount) 条建议等待决定") }
            Divider()
            Button("打开 Another You") {
                openWindow(id: "main")
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
            Button(store.paused ? "恢复主动建议" : "暂停主动建议") { store.togglePause() }
                .disabled(!store.isConnected || store.isChangingPause)
            Button("刷新连接") { store.refresh() }.disabled(store.connection == .starting || store.isRestarting)
            SettingsLink { Text("设置…") }
            Divider()
            Button("退出 Another You") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q")
        }
    }
}
