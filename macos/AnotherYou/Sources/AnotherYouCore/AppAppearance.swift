import AppKit

public enum AppAppearance: String, CaseIterable, Identifiable, Sendable {
    case system, light, dark

    public var id: String { rawValue }
    public var title: String { title(locale: AppLocalization.locale) }

    public func title(locale: Locale) -> String {
        switch self {
        case .system: AppLocalization.string("跟随系统", locale: locale)
        case .light: AppLocalization.string("日间", locale: locale)
        case .dark: AppLocalization.string("夜间", locale: locale)
        }
    }

    @MainActor
    func apply() {
        switch self {
        case .system: NSApplication.shared.appearance = nil
        case .light: NSApplication.shared.appearance = NSAppearance(named: .aqua)
        case .dark: NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        }
    }
}
