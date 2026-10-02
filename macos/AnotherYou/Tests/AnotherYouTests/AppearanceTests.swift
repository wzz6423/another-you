import AppKit
import XCTest
@testable import AnotherYouCore

@MainActor
final class AppearanceTests: XCTestCase {
    func testPreferencePersistsAndAppliesWhenStoreIsRecreated() throws {
        let suite = "another-you-appearance-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let originalAppearance = NSApplication.shared.appearance
        defer {
            defaults.removePersistentDomain(forName: suite)
            NSApplication.shared.appearance = originalAppearance
        }
        let repository = AgentSettingsRepository(dataDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(suite))
        let store = AssistantStore(repository: repository, defaults: defaults)
        XCTAssertEqual(store.appearance, .system)
        XCTAssertNil(NSApplication.shared.appearance)

        for preference in [AppAppearance.light, .dark] {
            store.setAppearance(preference)
            XCTAssertEqual(defaults.string(forKey: "appearance"), preference.rawValue)
            let expected: NSAppearance.Name = preference == .light ? .aqua : .darkAqua
            XCTAssertEqual(NSApplication.shared.appearance?.name, expected)
            NSApplication.shared.appearance = nil
            let restored = AssistantStore(repository: repository, defaults: defaults)
            XCTAssertEqual(restored.appearance, preference)
            XCTAssertEqual(NSApplication.shared.appearance?.name, expected)
        }
    }

    func testSystemAndUnknownPreferencesClearForcedAppearance() throws {
        let suite = "another-you-appearance-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let originalAppearance = NSApplication.shared.appearance
        defer {
            defaults.removePersistentDomain(forName: suite)
            NSApplication.shared.appearance = originalAppearance
        }
        let repository = AgentSettingsRepository(dataDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(suite))
        let store = AssistantStore(repository: repository, defaults: defaults)
        store.setAppearance(.dark)
        store.setAppearance(.system)
        XCTAssertNil(NSApplication.shared.appearance)
        let restored = AssistantStore(repository: repository, defaults: defaults)
        XCTAssertEqual(restored.appearance, .system)
        XCTAssertNil(NSApplication.shared.appearance)

        defaults.set("unknown-mode", forKey: "appearance")
        NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        let recovered = AssistantStore(repository: repository, defaults: defaults)
        XCTAssertEqual(recovered.appearance, .system)
        XCTAssertNil(NSApplication.shared.appearance)
    }
}
