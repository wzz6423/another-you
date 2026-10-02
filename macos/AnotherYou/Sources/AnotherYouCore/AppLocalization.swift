import Foundation

public enum AppLanguage: String, CaseIterable, Codable, Identifiable, Sendable {
    case simplifiedChinese = "zh-Hans"
    case traditionalChinese = "zh-Hant"
    case english = "en"
    case japanese = "ja"
    case korean = "ko"
    case french = "fr"
    case german = "de"
    case spanish = "es"
    case brazilianPortuguese = "pt-BR"
    case italian = "it"
    case dutch = "nl"
    case russian = "ru"
    case arabic = "ar"
    case thai = "th"
    case indonesian = "id"
    case vietnamese = "vi"
    case turkish = "tr"

    public var id: String { rawValue }
    public var locale: Locale { Locale(identifier: rawValue) }
    public var isRightToLeft: Bool { self == .arabic }

    public var nativeDisplayName: String {
        switch self {
        case .simplifiedChinese: "简体中文"
        case .traditionalChinese: "繁體中文"
        case .english: "English"
        case .japanese: "日本語"
        case .korean: "한국어"
        case .french: "Français"
        case .german: "Deutsch"
        case .spanish: "Español"
        case .brazilianPortuguese: "Português (Brasil)"
        case .italian: "Italiano"
        case .dutch: "Nederlands"
        case .russian: "Русский"
        case .arabic: "العربية"
        case .thai: "ไทย"
        case .indonesian: "Bahasa Indonesia"
        case .vietnamese: "Tiếng Việt"
        case .turkish: "Türkçe"
        }
    }

    public static func resolve(_ identifier: String) -> AppLanguage? {
        let parts = identifier.replacingOccurrences(of: "_", with: "-").lowercased().split(separator: "-")
        guard let language = parts.first else { return nil }
        if language == "zh" {
            if parts.contains("hans") { return .simplifiedChinese }
            if parts.contains("hant") || parts.contains("tw") || parts.contains("hk") || parts.contains("mo") {
                return .traditionalChinese
            }
            return .simplifiedChinese
        }
        if language == "pt" { return .brazilianPortuguese }
        return allCases.first { $0.rawValue.lowercased() == language }
    }

    public static func preferred(from identifiers: [String]) -> AppLanguage {
        identifiers.lazy.compactMap(resolve).first ?? .english
    }
}

public enum AppLocalization {
    public static let defaultsKey = "another-you.interface-language"

    public static var currentLanguage: AppLanguage {
        language(defaults: .standard, preferredLanguages: Locale.preferredLanguages)
    }

    public static var locale: Locale { currentLanguage.locale }

    public static func language(defaults: UserDefaults, preferredLanguages: [String]) -> AppLanguage {
        if let value = defaults.string(forKey: defaultsKey), let language = AppLanguage.resolve(value) {
            return language
        }
        return AppLanguage.preferred(from: preferredLanguages)
    }

    public static func text(_ key: String) -> String {
        string(key, language: currentLanguage)
    }

    public static func text(_ key: String, _ arguments: CVarArg...) -> String {
        format(key, language: currentLanguage, arguments)
    }

    public static func message(_ value: String) -> String {
        if value.hasPrefix("发现新版本 ") {
            return text("发现新版本 %@", String(value.dropFirst("发现新版本 ".count)))
        }
        if value.hasPrefix("所选 Pi 模型不存在：") {
            return text("所选 Pi 模型不存在：%@", String(value.dropFirst("所选 Pi 模型不存在：".count)))
        }
        for file in ["auth.json", "settings.json", "models.json"] where value.hasPrefix("\(file) 无法读取") {
            return text("%@ 无法读取，请检查模型配置", file)
        }
        if value == "请先在设置中选择模型并配置账户。" {
            return text("请在设置中选择模型并配置账户")
        }
        return text(value)
    }

    public static func string(_ key: String, language: AppLanguage) -> String {
        localizationBundles[language]?.localizedString(forKey: key, value: key, table: "Localizable") ?? key
    }

    public static func string(_ key: String, locale: Locale) -> String {
        string(key, language: AppLanguage.resolve(locale.identifier) ?? .english)
    }

    public static func format(_ key: String, language: AppLanguage, _ arguments: [CVarArg]) -> String {
        String(format: string(key, language: language), locale: language.locale, arguments: arguments)
    }

    public static func format(_ key: String, locale: Locale, _ arguments: [CVarArg]) -> String {
        String(format: string(key, locale: locale), locale: locale, arguments: arguments)
    }

    public static func number(_ value: Int) -> String {
        value.formatted(.number.locale(locale))
    }

    public static func reasoningEffort(_ value: String, locale: Locale = AppLocalization.locale) -> String {
        let keys = ["off": "关闭", "minimal": "最低", "low": "低", "medium": "中",
                    "high": "高", "xhigh": "很高", "max": "最高", "unknown": "未报告"]
        return string(keys[value] ?? value, locale: locale)
    }

    public static func date(_ value: Date, includeDate: Bool = true) -> String {
        value.formatted(Date.FormatStyle(date: includeDate ? .abbreviated : .omitted, time: .shortened).locale(locale))
    }

    // 优先读取实际应用内的资源，避免依赖 SwiftPM accessor 内嵌的构建目录回退路径。
    public static let resourceBundle: Bundle = {
        if let url = Bundle.main.resourceURL?.appendingPathComponent("AnotherYou_AnotherYouCore.bundle"),
           let bundle = Bundle(url: url) {
            return bundle
        }
        return Bundle.module
    }()

    private static let localizationBundles: [AppLanguage: Bundle] = {
        var bundles: [AppLanguage: Bundle] = [:]
        for language in AppLanguage.allCases {
            let identifier = resourceBundle.localizations.first {
                $0.caseInsensitiveCompare(language.rawValue) == .orderedSame
            } ?? language.rawValue
            if let url = resourceBundle.url(forResource: identifier, withExtension: "lproj"),
               let bundle = Bundle(url: url) {
                bundles[language] = bundle
            }
        }
        return bundles
    }()
}
