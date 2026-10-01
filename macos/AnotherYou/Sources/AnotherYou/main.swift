import SwiftUI
import AnotherYouCore

@main
struct AnotherYouApp: App {
    var body: some Scene {
        WindowGroup {
            MainWindowView()
        }
        .defaultSize(width: 1040, height: 780)
        .windowStyle(.hiddenTitleBar)

        Settings {
            SettingsView()
        }
    }
}
