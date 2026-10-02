import AppKit
import Combine
import SwiftUI

@MainActor
public final class AppLanguageStore: ObservableObject {
    public static let shared = AppLanguageStore()

    @Published public var selection: AppLanguage? {
        didSet {
            guard selection != oldValue else { return }
            if let selection {
                defaults.set(selection.rawValue, forKey: AppLocalization.defaultsKey)
            } else {
                defaults.removeObject(forKey: AppLocalization.defaultsKey)
            }
            refreshSystemLanguage()
        }
    }
    @Published public private(set) var language: AppLanguage
    public var locale: Locale { language.locale }
    public var layoutDirection: LayoutDirection { language.isRightToLeft ? .rightToLeft : .leftToRight }

    private let defaults: UserDefaults
    private let preferredLanguages: () -> [String]
    private var localeObserver: AnyCancellable?

    public init(defaults: UserDefaults = .standard, preferredLanguages: @escaping () -> [String] = { Locale.preferredLanguages }) {
        self.defaults = defaults
        self.preferredLanguages = preferredLanguages
        let savedLanguage = defaults.string(forKey: AppLocalization.defaultsKey).flatMap(AppLanguage.resolve)
        selection = savedLanguage
        language = savedLanguage ?? AppLanguage.preferred(from: preferredLanguages())
        localeObserver = NotificationCenter.default.publisher(for: NSLocale.currentLocaleDidChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.refreshSystemLanguage() }
            }
    }

    public func refreshSystemLanguage() {
        let effectiveLanguage = selection ?? AppLanguage.preferred(from: preferredLanguages())
        if language != effectiveLanguage { language = effectiveLanguage }
    }
}

public struct LanguageSettingsView: View {
    @ObservedObject private var languages = AppLanguageStore.shared

    public init() {}

    public var body: some View {
        Section(AppLocalization.text("语言")) {
            Picker(AppLocalization.text("界面语言"), selection: $languages.selection) {
                Text(AppLocalization.text("跟随系统")).tag(Optional<AppLanguage>.none)
                ForEach(AppLanguage.allCases) { language in
                    Text(verbatim: language.nativeDisplayName).tag(Optional(language))
                }
            }
        }
    }
}

// SwiftUI Window 的初始标题不会随语言切换更新已打开窗口。
struct LocalizedWindowTitle: NSViewRepresentable {
    @Environment(\.locale) private var locale
    let key: String

    func makeNSView(context: Context) -> TitleView { TitleView() }

    func updateNSView(_ view: TitleView, context: Context) {
        view.localizedTitle = AppLocalization.string(key, locale: locale)
    }

    final class TitleView: NSView {
        var localizedTitle = "" {
            didSet { updateTitle() }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            updateTitle()
        }

        private func updateTitle() {
            if let window, window.title != localizedTitle { window.title = localizedTitle }
        }
    }
}
