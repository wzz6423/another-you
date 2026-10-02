import AppKit
import Carbon
import SwiftUI
import XCTest
@testable import AnotherYouCore

@MainActor
private final class TestShortcutRegistrar: GlobalShortcutRegistering {
    var onTrigger: ((ShortcutAction) -> Void)?
    var registered: [ShortcutAction: HotKey] = [:]
    var errors: [ShortcutAction: String] = [:]
    var unregisterCount = 0

    func register(_ hotKey: HotKey, for action: ShortcutAction) -> String? {
        if let error = errors[action] { return error }
        registered[action] = hotKey
        return nil
    }

    func unregisterAll() {
        unregisterCount += 1
        registered = [:]
    }
}

@MainActor
final class ShortcutTests: XCTestCase {
    private func withStore(_ test: (ShortcutStore, UserDefaults) throws -> Void) rethrows {
        let name = "another-you-shortcut-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        try test(ShortcutStore(defaults: defaults), defaults)
    }

    private func event(_ keyCode: Int, flags: NSEvent.ModifierFlags = [], repeat isRepeat: Bool = false) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                        context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: isRepeat, keyCode: UInt16(keyCode))!
    }

    func testDefaultsCoverEveryActionAndDoNotConflict() {
        withStore { store, _ in
            XCTAssertEqual(store.hotKeys.count, ShortcutAction.allCases.count)
            XCTAssertEqual(Set(store.hotKeys.values).count, store.hotKeys.count)
            XCTAssertEqual(ShortcutAction.allCases.filter(\.isGlobal).count, 4)
            for action in ShortcutAction.allCases {
                XCTAssertTrue(store.hotKey(for: action)!.isValid(for: action), action.rawValue)
            }
        }
    }

    func testRemapClearAndRestorePersistAcrossLaunches() throws {
        try withStore { store, defaults in
            let replacement = HotKey(keyCode: UInt32(kVK_ANSI_R), modifiers: UInt32(cmdKey | optionKey))
            try store.set(replacement, for: .captureRegion)
            store.clear(.quit)
            let reloaded = ShortcutStore(defaults: defaults)
            XCTAssertEqual(reloaded.hotKey(for: .captureRegion), replacement)
            XCTAssertNil(reloaded.hotKey(for: .quit))
            XCTAssertEqual(reloaded.label(for: .quit), "未设置")
            reloaded.restoreDefaults()
            let restored = ShortcutStore(defaults: defaults)
            XCTAssertEqual(restored.hotKey(for: .captureRegion), ShortcutAction.captureRegion.defaultHotKey)
            XCTAssertEqual(restored.hotKey(for: .quit), ShortcutAction.quit.defaultHotKey)
        }
    }

    func testDuplicateBetweenGlobalAndLocalActionsIsRejectedWithoutMutation() throws {
        try withStore { store, _ in
            let original = store.hotKey(for: .captureRegion)
            XCTAssertThrowsError(try store.set(store.hotKey(for: .sendMessage), for: .captureRegion)) { error in
                XCTAssertEqual(error as? ShortcutError, .conflict(.sendMessage))
            }
            XCTAssertEqual(store.hotKey(for: .captureRegion), original)
            XCTAssertThrowsError(try store.set(store.hotKey(for: .quickChat), for: .quit)) { error in
                XCTAssertEqual(error as? ShortcutError, .conflict(.quickChat))
            }
            store.clear(.sendMessage)
            try store.set(ShortcutAction.sendMessage.defaultHotKey, for: .captureRegion)
            XCTAssertEqual(store.hotKey(for: .captureRegion), ShortcutAction.sendMessage.defaultHotKey)
        }
    }

    func testPlainTextAndModifierKeysRejectedWhileLocalReturnAllowed() throws {
        try withStore { store, _ in
            for key in [HotKey(keyCode: UInt32(kVK_ANSI_A), modifiers: 0),
                        HotKey(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(shiftKey)),
                        HotKey(keyCode: UInt32(kVK_Command), modifiers: UInt32(cmdKey)),
                        HotKey(keyCode: 65535, modifiers: UInt32(cmdKey))] {
                XCTAssertThrowsError(try store.set(key, for: .sendMessage))
            }
            let returnKey = HotKey(keyCode: UInt32(kVK_Return), modifiers: 0)
            XCTAssertThrowsError(try store.set(returnKey, for: .quickChat))
            try store.set(returnKey, for: .sendMessage)
            XCTAssertEqual(store.hotKey(for: .sendMessage), returnKey)
        }
    }

    func testRecordingStripsCapsLockAndFunctionFlagsAndPersists() {
        withStore { store, defaults in
            store.beginRecording(.quickChat)
            store.record(event(kVK_ANSI_K, flags: [.command, .option, .capsLock, .function]))
            let expected = HotKey(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(cmdKey | optionKey))
            XCTAssertEqual(store.hotKey(for: .quickChat), expected)
            XCTAssertEqual(ShortcutStore(defaults: defaults).hotKey(for: .quickChat), expected)
            XCTAssertNil(store.recordingAction)
            XCTAssertTrue(expected.matches(event(kVK_ANSI_K, flags: [.command, .option, .capsLock])))
            XCTAssertFalse(expected.matches(event(kVK_ANSI_K, flags: [.command])))
        }
    }

    func testRecordingEscapeCancelsAndDuplicateAllowsRetry() {
        withStore { store, _ in
            let original = store.hotKey(for: .captureRegion)
            store.beginRecording(.captureRegion)
            store.record(event(kVK_Return, flags: .command))
            XCTAssertEqual(store.recordingAction, .captureRegion)
            XCTAssertNotNil(store.recordingError)
            XCTAssertEqual(store.hotKey(for: .captureRegion), original)
            store.record(event(kVK_Escape))
            XCTAssertNil(store.recordingAction)
            XCTAssertNil(store.recordingError)
            XCTAssertEqual(store.hotKey(for: .captureRegion), original)
            store.beginRecording(.captureRegion)
            store.record(event(kVK_ANSI_K, flags: .command, repeat: true))
            XCTAssertEqual(store.recordingAction, .captureRegion)
            XCTAssertEqual(store.hotKey(for: .captureRegion), original)
            store.record(event(kVK_ANSI_K, flags: .command))
            XCTAssertEqual(store.hotKey(for: .captureRegion), HotKey(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(cmdKey)))
        }
    }

    func testCorruptOrConflictingSavedPreferencesFallBackToValidDefaults() {
        withStore { _, defaults in
            for raw in ["invalid", "{\"quickChat\":{\"hotKey\":{\"keyCode\":36,\"modifiers\":256}}}"] {
                defaults.set(Data(raw.utf8), forKey: ShortcutStore.preferenceKey)
                let reloaded = ShortcutStore(defaults: defaults)
                XCTAssertEqual(reloaded.hotKey(for: .quickChat), ShortcutAction.quickChat.defaultHotKey)
                XCTAssertEqual(Set(reloaded.hotKeys.values).count, reloaded.hotKeys.count)
            }
        }
    }

    func testModifiedEscapeCanBeRecordedWithoutCancelling() {
        withStore { store, _ in
            store.beginRecording(.stop)
            store.record(event(kVK_Escape, flags: .command))
            XCTAssertNil(store.recordingAction)
            XCTAssertEqual(store.hotKey(for: .stop), HotKey(keyCode: UInt32(kVK_Escape), modifiers: UInt32(cmdKey)))
        }
    }

    func testCoordinatorSuspendsAndResumesDuringRecordingAndStopsCleanly() throws {
        try withStore { store, _ in
            let registrar = TestShortcutRegistrar()
            var triggered: [ShortcutAction] = []
            let coordinator = GlobalShortcutCoordinator(store: store, registrar: registrar) { triggered.append($0) }
            coordinator.start()
            XCTAssertEqual(registrar.registered.count, 4)
            let count = registrar.unregisterCount
            coordinator.start()
            XCTAssertEqual(registrar.unregisterCount, count)
            registrar.onTrigger?(.quickChat)
            XCTAssertEqual(triggered, [.quickChat])
            store.beginRecording(.quit)
            XCTAssertTrue(registrar.registered.isEmpty)
            registrar.onTrigger?(.quickChat)
            XCTAssertEqual(triggered, [.quickChat])
            store.cancelRecording()
            XCTAssertEqual(registrar.registered.count, 4)
            let replacement = HotKey(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(cmdKey | shiftKey))
            try store.set(replacement, for: .quickChat)
            XCTAssertEqual(registrar.registered[.quickChat], replacement)
            store.clear(.quickChat)
            XCTAssertNil(registrar.registered[.quickChat])
            registrar.onTrigger?(.quickChat)
            XCTAssertEqual(triggered, [.quickChat])
            coordinator.stop()
            XCTAssertTrue(registrar.registered.isEmpty)
            XCTAssertNil(registrar.onTrigger)
            store.restoreDefaults()
            XCTAssertTrue(registrar.registered.isEmpty)
        }
    }

    func testSystemRegistrationFailureIsVisibleAndClearsAfterRemapping() throws {
        try withStore { store, _ in
            let registrar = TestShortcutRegistrar()
            registrar.errors[.quickChat] = "快捷键已被占用"
            let coordinator = GlobalShortcutCoordinator(store: store, registrar: registrar) { _ in }
            coordinator.start()
            defer { coordinator.stop() }
            XCTAssertEqual(store.registrationErrors[.quickChat], "快捷键已被占用")
            XCTAssertEqual(registrar.registered.count, 3)
            registrar.errors = [:]
            try store.set(HotKey(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(cmdKey | optionKey)), for: .quickChat)
            XCTAssertTrue(store.registrationErrors.isEmpty)
            XCTAssertEqual(registrar.registered.count, 4)
        }
    }

    func testCarbonRegistrationReportsCollisionAndReleasesAfterStop() throws {
        try withStore { store, _ in
            for action in ShortcutAction.allCases where action.isGlobal { store.clear(action) }
            let hotKey = HotKey(keyCode: UInt32(kVK_F20), modifiers: UInt32(cmdKey | controlKey | optionKey | shiftKey))
            try store.set(hotKey, for: .captureRegion)
            var occupied: EventHotKeyRef?
            let identifier = EventHotKeyID(signature: 0x41595453, id: 1)
            let status = RegisterEventHotKey(hotKey.keyCode, hotKey.modifiers, identifier, GetApplicationEventTarget(), 0, &occupied)
            guard status == noErr, occupied != nil else { throw XCTSkip("当前环境无法预留测试热键：\(status)") }
            defer { if let occupied { UnregisterEventHotKey(occupied) } }
            let coordinator = GlobalShortcutCoordinator(store: store) { _ in }
            defer { coordinator.stop() }
            coordinator.start()
            XCTAssertNotNil(store.registrationErrors[.captureRegion])
            UnregisterEventHotKey(occupied!)
            occupied = nil
            try store.set(hotKey, for: .captureRegion)
            XCTAssertNil(store.registrationErrors[.captureRegion])
            coordinator.stop()
            XCTAssertEqual(RegisterEventHotKey(hotKey.keyCode, hotKey.modifiers, identifier, GetApplicationEventTarget(), 0, &occupied), noErr)
        }
    }

    func testCodableHotKeyAndSwiftUIEquivalentsKeepModifiers() throws {
        let hotKey = ShortcutAction.sendMessage.defaultHotKey
        XCTAssertEqual(try JSONDecoder().decode(HotKey.self, from: JSONEncoder().encode(hotKey)), hotKey)
        XCTAssertEqual(hotKey.keyEquivalent, KeyEquivalent.return)
        XCTAssertEqual(hotKey.eventModifiers, .command)
        XCTAssertEqual(hotKey.label, "⌘↩")
        XCTAssertEqual(ShortcutAction.closeQuickChat.defaultHotKey.keyEquivalent, KeyEquivalent.escape)
        XCTAssertEqual(ShortcutAction.quickChat.defaultHotKey.label, "⇧⌘Space")
        XCTAssertEqual(HotKey(keyCode: UInt32(kVK_Delete), modifiers: UInt32(cmdKey)).keyEquivalent, KeyEquivalent.delete)
        XCTAssertEqual(HotKey(keyCode: UInt32(kVK_ForwardDelete), modifiers: UInt32(cmdKey)).keyEquivalent, KeyEquivalent.deleteForward)
    }
}
