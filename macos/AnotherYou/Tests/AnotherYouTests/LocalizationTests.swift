import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import AnotherYouCore

final class LocalizationTests: XCTestCase {
    func testLanguageResolutionAndFallback() {
        XCTAssertEqual(AppLanguage.allCases.count, 17)
        for language in AppLanguage.allCases {
            XCTAssertEqual(AppLanguage.resolve(language.rawValue), language)
        }
        XCTAssertEqual(AppLanguage.resolve("zh_HK"), .traditionalChinese)
        XCTAssertEqual(AppLanguage.resolve("zh-Hans-TW"), .simplifiedChinese)
        XCTAssertEqual(AppLanguage.resolve("zh-MO"), .traditionalChinese)
        XCTAssertEqual(AppLanguage.resolve("pt-PT"), .brazilianPortuguese)
        XCTAssertEqual(AppLanguage.resolve("en-GB"), .english)
        XCTAssertEqual(AppLanguage.preferred(from: ["unknown", "ko-KR", "fr"]), .korean)
        XCTAssertEqual(AppLanguage.preferred(from: []), .english)
        XCTAssertEqual(AppLanguage.preferred(from: ["unknown"]), .english)
    }

    @MainActor
    func testLanguagePreferencePersistsAndSystemModeRefreshes() throws {
        let suite = "another-you-localization-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var preferred = ["zh-TW"]
        let store = AppLanguageStore(defaults: defaults, preferredLanguages: { preferred })
        XCTAssertNil(store.selection)
        XCTAssertEqual(store.language, .traditionalChinese)
        store.selection = .arabic
        XCTAssertEqual(defaults.string(forKey: AppLocalization.defaultsKey), "ar")
        XCTAssertEqual(store.layoutDirection, .rightToLeft)
        let restored = AppLanguageStore(defaults: defaults, preferredLanguages: { ["ja"] })
        XCTAssertEqual(restored.language, .arabic)
        XCTAssertEqual(restored.selection, .arabic)
        preferred = ["de-DE"]
        store.refreshSystemLanguage()
        XCTAssertEqual(store.language, .arabic)
        store.selection = nil
        XCTAssertNil(defaults.object(forKey: AppLocalization.defaultsKey))
        XCTAssertEqual(store.language, .german)
        XCTAssertEqual(store.layoutDirection, .leftToRight)
        preferred = ["unsupported", "vi"]
        store.refreshSystemLanguage()
        XCTAssertEqual(store.language, .vietnamese)
        defaults.set("unsupported", forKey: AppLocalization.defaultsKey)
        let recovered = AppLanguageStore(defaults: defaults, preferredLanguages: { ["th"] })
        XCTAssertNil(recovered.selection)
        XCTAssertEqual(recovered.language, .thai)
    }

    func testEveryLanguageHasTheSameCompleteResourceKeysAndFormatArguments() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/AnotherYouCore/Resources")
        func dictionary(_ language: AppLanguage) throws -> [String: String] {
            let url = root.appendingPathComponent("\(language.rawValue).lproj/Localizable.strings")
            let data = try Data(contentsOf: url)
            return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
        }
        let base = try dictionary(.english)
        XCTAssertGreaterThanOrEqual(base.count, 295)
        let format = try NSRegularExpression(pattern: "%[0-9$.*+-]*[diu@]")
        func arguments(_ value: String) -> [String] {
            format.matches(in: value, range: NSRange(value.startIndex..., in: value)).map {
                String(value[Range($0.range, in: value)!])
            }
        }
        for language in AppLanguage.allCases {
            let strings = try dictionary(language)
            XCTAssertEqual(Set(strings.keys), Set(base.keys), language.rawValue)
            for (key, value) in strings {
                XCTAssertFalse(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "\(language): \(key)")
                XCTAssertEqual(arguments(key), arguments(value), "\(language): \(key)")
                XCTAssertFalse(value.contains("TODO") || value.contains("TRANSLATE") || value.contains("PLACEHOLDER"))
                if ![.simplifiedChinese, .traditionalChinese, .japanese].contains(language) {
                    XCTAssertNil(value.range(of: "[\\u4e00-\\u9fff]", options: .regularExpression), "\(language): \(key)")
                }
                XCTAssertEqual(AppLocalization.string(key, language: language), value, "Bundle lookup: \(language): \(key)")
            }
        }

        let sources = root.deletingLastPathComponent().deletingLastPathComponent()
        let files = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        let literalKey = try NSRegularExpression(pattern: #"AppLocalization\.(?:text|format)\("([^"\\]+)""#)
        for case let file as URL in files where file.pathExtension == "swift" {
            let source = try String(contentsOf: file, encoding: .utf8)
            for match in literalKey.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
                let key = String(source[Range(match.range(at: 1), in: source)!])
                XCTAssertNotNil(base[key], "Missing source key in \(file.lastPathComponent): \(key)")
            }
        }
    }

    func testFormattedStringsPreserveValuesAndUnknownKeys() {
        for language in AppLanguage.allCases {
            let result = AppLocalization.format("输入 %@ · 输出 %@ · 缓存 %@", language: language, ["123", "456", "789"])
            for value in ["123", "456", "789"] { XCTAssertTrue(result.contains(value)) }
            XCTAssertFalse(result.contains("%@"))
            XCTAssertEqual(AppLocalization.string("unknown-test-key", language: language), "unknown-test-key")
        }
        XCTAssertEqual(AppLocalization.format("%d 个模型", language: .english, [3]), "3 models")
        XCTAssertEqual(AppLocalization.string("设置", locale: Locale(identifier: "fr-CA")), "Réglages")
    }

    func testRuntimeMessagesPreserveVersionModelAndFileValues() {
        XCTAssertEqual(AppLocalization.message("发现新版本 1.2.3"), AppLocalization.text("发现新版本 %@", "1.2.3"))
        XCTAssertEqual(AppLocalization.message("所选 Pi 模型不存在：provider/model"),
                       AppLocalization.text("所选 Pi 模型不存在：%@", "provider/model"))
        XCTAssertEqual(AppLocalization.message("settings.json 无法读取，请检查模型设置"),
                       AppLocalization.text("%@ 无法读取，请检查模型配置", "settings.json"))
        XCTAssertEqual(AppLocalization.message("Unrecognized external diagnostic"), "Unrecognized external diagnostic")
    }

    func testEnumLabelsUseExplicitInterfaceLocale() {
        let english = Locale(identifier: "en")
        let chinese = Locale(identifier: "zh-Hans")
        XCTAssertEqual(AppAppearance.allCases.map { $0.title(locale: english) }, ["System default", "Light", "Dark"])
        XCTAssertEqual(AppAppearance.allCases.map { $0.title(locale: chinese) }, ["跟随系统", "日间", "夜间"])
        XCTAssertEqual(UsagePeriod.allCases.map { $0.title(locale: english) }, ["24 hours", "7 days", "15 days", "30 days"])
        XCTAssertEqual(ShortcutAction.quickChat.label(locale: english), "Quick chat")
        XCTAssertEqual(ShortcutAction.quickChat.label(locale: chinese), "快速会话")
        XCTAssertEqual(ActivityCategory.thinking.title(locale: english), "Thinking")
        XCTAssertEqual(ActivityCategory.thinking.title(locale: chinese), "思考")
        XCTAssertEqual(AppLocalization.reasoningEffort("medium", locale: english), "Medium")
        XCTAssertEqual(CardState.completed.label(locale: english), "Draft ready")
    }

    @MainActor
    func testOpenSettingsUpdatesLanguageWithoutReplacingWindowOrLosingDraft() throws {
        let suite = "another-you-language-window-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let originalAppearance = NSApplication.shared.appearance
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
            NSApplication.shared.appearance = originalAppearance
        }
        let store = AssistantStore(repository: AgentSettingsRepository(dataDirectory: directory), defaults: defaults)
        store.setInputDraft("keep this unsent draft", for: .conversation)
        let language = InterfaceLocaleFixture()
        let host = NSHostingView(rootView: SettingsLanguageFixture(store: store, language: language))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 620),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }

        func segments(in view: NSView) -> NSSegmentedControl? {
            if let control = view as? NSSegmentedControl { return control }
            return view.subviews.lazy.compactMap { segments(in: $0) }.first
        }
        func waitForLabels(_ labels: [String], title: String) {
            let deadline = Date().addingTimeInterval(2)
            while Date() < deadline {
                host.layoutSubtreeIfNeeded()
                if let control = segments(in: host), window.title == title,
                   (0..<control.segmentCount).map({ control.label(forSegment: $0) ?? "" }) == labels { return }
                RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            }
            XCTFail("Settings did not update title and segmented labels: \(window.title)")
        }

        waitForLabels(["跟随系统", "日间", "夜间"], title: "设置")
        language.locale = Locale(identifier: "en")
        waitForLabels(["System default", "Light", "Dark"], title: "Settings")
        language.locale = Locale(identifier: "zh-Hans")
        waitForLabels(["跟随系统", "日间", "夜间"], title: "设置")
        XCTAssertTrue(window.contentView === host)
        XCTAssertEqual(store.draft(for: .conversation).text, "keep this unsent draft")
        XCTAssertEqual(store.appearance, .system)
    }
}

@MainActor
private final class InterfaceLocaleFixture: ObservableObject {
    @Published var locale = Locale(identifier: "zh-Hans")
}

private struct SettingsLanguageFixture: View {
    let store: AssistantStore
    @ObservedObject var language: InterfaceLocaleFixture

    var body: some View {
        SettingsView(store: store).environment(\.locale, language.locale)
    }
}
