import AppKit
import ApplicationServices
import Carbon
import Combine
import SwiftUI

public enum ShortcutAction: String, CaseIterable, Codable, Identifiable, Sendable {
    case quickChat, captureRegion, captureWindow, captureScreen
    case sendMessage, settings, quit, stop, closeQuickChat

    public var id: String { rawValue }
    public var isGlobal: Bool {
        switch self {
        case .quickChat, .captureRegion, .captureWindow, .captureScreen: true
        default: false
        }
    }
    public var label: String { label(locale: AppLocalization.locale) }

    public func label(locale: Locale) -> String {
        switch self {
        case .quickChat: AppLocalization.string("快速会话", locale: locale)
        case .captureRegion: AppLocalization.string("截取选定区域", locale: locale)
        case .captureWindow: AppLocalization.string("截取前台窗口", locale: locale)
        case .captureScreen: AppLocalization.string("截取整个屏幕", locale: locale)
        case .sendMessage: AppLocalization.string("发送消息", locale: locale)
        case .settings: AppLocalization.string("打开设置", locale: locale)
        case .quit: AppLocalization.string("退出 Another You", locale: locale)
        case .stop: AppLocalization.string("停止当前任务", locale: locale)
        case .closeQuickChat: AppLocalization.string("关闭快速会话", locale: locale)
        }
    }
    public var defaultHotKey: HotKey {
        switch self {
        case .quickChat: HotKey(keyCode: UInt32(kVK_Space), modifiers: UInt32(cmdKey | shiftKey))
        case .captureRegion: HotKey(keyCode: UInt32(kVK_ANSI_4), modifiers: UInt32(cmdKey | shiftKey | optionKey))
        case .captureWindow: HotKey(keyCode: UInt32(kVK_Option), modifiers: UInt32(controlKey | optionKey))
        case .captureScreen: HotKey(keyCode: UInt32(kVK_ANSI_3), modifiers: UInt32(cmdKey | shiftKey | optionKey))
        case .sendMessage: HotKey(keyCode: UInt32(kVK_Return), modifiers: UInt32(cmdKey))
        case .settings: HotKey(keyCode: UInt32(kVK_ANSI_Comma), modifiers: UInt32(cmdKey))
        case .quit: HotKey(keyCode: UInt32(kVK_ANSI_Q), modifiers: UInt32(cmdKey))
        case .stop: HotKey(keyCode: UInt32(kVK_ANSI_Period), modifiers: UInt32(cmdKey))
        case .closeQuickChat: HotKey(keyCode: UInt32(kVK_Escape), modifiers: 0)
        }
    }
}

public struct HotKey: Codable, Hashable, Sendable {
    public let keyCode: UInt32
    public let modifiers: UInt32
    private static let modifierMask = UInt32(cmdKey | controlKey | optionKey | shiftKey)

    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers & Self.modifierMask
    }

    public init(event: NSEvent) {
        var modifiers: UInt32 = 0
        if event.modifierFlags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if event.modifierFlags.contains(.control) { modifiers |= UInt32(controlKey) }
        if event.modifierFlags.contains(.option) { modifiers |= UInt32(optionKey) }
        if event.modifierFlags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        self.init(keyCode: UInt32(event.keyCode), modifiers: modifiers)
    }

    public func matches(_ event: NSEvent) -> Bool { self == HotKey(event: event) }

    public var isModifierOnly: Bool { keyCode == UInt32(kVK_Option) && modifiers == UInt32(controlKey | optionKey) }

    public func isValid(for action: ShortcutAction) -> Bool {
        if isModifierOnly { return action == .captureWindow }
        let modifierKeys: Set<UInt32> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]
        guard keyCode <= 127, !modifierKeys.contains(keyCode), modifiers & ~Self.modifierMask == 0 else { return false }
        if modifiers & UInt32(cmdKey | controlKey | optionKey) != 0 { return true }
        return !action.isGlobal && (Self.specialKeys[keyCode] != nil || Self.functionKeys[keyCode] != nil)
    }

    @MainActor
    public var label: String {
        var result = ""
        if modifiers & UInt32(controlKey) != 0 { result += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { result += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { result += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { result += "⌘" }
        if isModifierOnly { return result }
        if keyCode == UInt32(kVK_Space) { return result + "Space" }
        if let special = Self.specialKeys[keyCode] { return result + special.label }
        if let number = Self.functionKeys[keyCode] { return result + "F\(number)" }
        return result + (translatedCharacter?.uppercased() ?? AppLocalization.text("键 %d", keyCode))
    }

    @MainActor
    public var keyEquivalent: KeyEquivalent? {
        if isModifierOnly { return nil }
        if let special = Self.specialKeys[keyCode] { return special.equivalent }
        if let number = Self.functionKeys[keyCode], let scalar = UnicodeScalar(0xF703 + number) {
            return KeyEquivalent(Character(scalar))
        }
        return translatedCharacter?.first.map { KeyEquivalent($0) }
    }

    public var eventModifiers: SwiftUI.EventModifiers {
        var result: SwiftUI.EventModifiers = []
        if modifiers & UInt32(cmdKey) != 0 { result.insert(.command) }
        if modifiers & UInt32(controlKey) != 0 { result.insert(.control) }
        if modifiers & UInt32(optionKey) != 0 { result.insert(.option) }
        if modifiers & UInt32(shiftKey) != 0 { result.insert(.shift) }
        return result
    }

    private static let specialKeys: [UInt32: (label: String, equivalent: KeyEquivalent)] = [
        36: ("↩", .return), 48: ("⇥", .tab), 51: ("⌫", .delete), 53: ("⎋", .escape),
        71: ("Clear", .clear), 76: ("⌤", KeyEquivalent("\u{03}")), 115: ("↖", .home),
        116: ("⇞", .pageUp), 117: ("⌦", .deleteForward), 119: ("↘", .end),
        121: ("⇟", .pageDown), 123: ("←", .leftArrow), 124: ("→", .rightArrow),
        125: ("↓", .downArrow), 126: ("↑", .upArrow)
    ]
    private static let functionKeys: [UInt32: UInt32] = [
        122: 1, 120: 2, 99: 3, 118: 4, 96: 5, 97: 6, 98: 7, 100: 8, 101: 9, 109: 10,
        103: 11, 111: 12, 105: 13, 107: 14, 113: 15, 106: 16, 64: 17, 79: 18, 80: 19, 90: 20
    ]

    @MainActor
    private var translatedCharacter: String? {
        // 输入法本身可能不提供键盘布局，使用其底层布局使中英文输入法共用同一物理按键。
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(data) else { return nil }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        var deadKeyState: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 4)
        let result = UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0,
                                    UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysMask),
                                    &deadKeyState, characters.count, &length, &characters)
        guard result == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: characters, count: length)
    }
}

public enum ShortcutError: LocalizedError, Equatable {
    case invalid, conflict(ShortcutAction)

    public var errorDescription: String? {
        switch self {
        case .invalid: AppLocalization.text("请使用 ⌘、⌃ 或 ⌥ 加一个按键；应用内也可使用回车、方向键或功能键。")
        case .conflict(let action): AppLocalization.text("该组合已用于“%@”，请换一个组合，或先清除原快捷键。", action.label)
        }
    }
}

@MainActor
public final class ShortcutStore: ObservableObject {
    public static let shared = ShortcutStore()
    @Published public private(set) var hotKeys: [ShortcutAction: HotKey]
    @Published public private(set) var recordingAction: ShortcutAction?
    @Published public private(set) var recordingError: String?
    @Published public private(set) var registrationErrors: [ShortcutAction: String] = [:]
    private let defaults: UserDefaults
    static let preferenceKey = "AnotherYou.Shortcuts.v1"

    private struct Binding: Codable { let hotKey: HotKey? }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var loaded = Self.defaultHotKeys
        if let data = defaults.data(forKey: Self.preferenceKey),
           let bindings = try? JSONDecoder().decode([String: Binding].self, from: data) {
            for (key, binding) in bindings {
                guard let action = ShortcutAction(rawValue: key) else { continue }
                if let hotKey = binding.hotKey {
                    if hotKey.isValid(for: action) { loaded[action] = hotKey }
                } else { loaded.removeValue(forKey: action) }
            }
        }
        hotKeys = Set(loaded.values).count == loaded.count ? loaded : Self.defaultHotKeys
    }

    public func hotKey(for action: ShortcutAction) -> HotKey? { hotKeys[action] }
    public func label(for action: ShortcutAction) -> String { hotKeys[action]?.label ?? AppLocalization.text("未设置") }

    public func set(_ hotKey: HotKey?, for action: ShortcutAction) throws {
        if let hotKey {
            guard hotKey.isValid(for: action) else { throw ShortcutError.invalid }
            if let conflict = ShortcutAction.allCases.first(where: { $0 != action && hotKeys[$0] == hotKey }) {
                throw ShortcutError.conflict(conflict)
            }
        }
        var updated = hotKeys
        updated[action] = hotKey
        hotKeys = updated
        persist()
    }

    public func clear(_ action: ShortcutAction) {
        try? set(nil, for: action)
        if recordingAction == action { cancelRecording() }
    }

    public func restoreDefaults() {
        cancelRecording()
        hotKeys = Self.defaultHotKeys
        persist()
    }

    public func beginRecording(_ action: ShortcutAction) {
        recordingError = nil
        recordingAction = action
    }

    public func cancelRecording() {
        recordingAction = nil
        recordingError = nil
    }

    public func record(_ event: NSEvent) {
        guard let action = recordingAction else { return }
        if event.type == .flagsChanged {
            guard action == .captureWindow, ModifierChord.normalized(event.modifierFlags) == [.control, .option] else { return }
            try? set(ShortcutAction.captureWindow.defaultHotKey, for: action)
            cancelRecording()
            return
        }
        guard event.type == .keyDown, !event.isARepeat else { return }
        let hotKey = HotKey(event: event)
        if event.keyCode == UInt16(kVK_Escape), hotKey.modifiers == 0 { cancelRecording(); return }
        do {
            try set(hotKey, for: action)
            cancelRecording()
        } catch { recordingError = error.localizedDescription }
    }

    func setRegistrationErrors(_ errors: [ShortcutAction: String]) {
        if registrationErrors != errors { registrationErrors = errors }
    }

    private static var defaultHotKeys: [ShortcutAction: HotKey] {
        Dictionary(uniqueKeysWithValues: ShortcutAction.allCases.map { ($0, $0.defaultHotKey) })
    }

    private func persist() {
        let bindings = Dictionary(uniqueKeysWithValues: ShortcutAction.allCases.map { ($0.rawValue, Binding(hotKey: hotKeys[$0])) })
        if let data = try? JSONEncoder().encode(bindings) { defaults.set(data, forKey: Self.preferenceKey) }
    }
}

@MainActor
protocol GlobalShortcutRegistering: AnyObject {
    var onTrigger: ((ShortcutAction) -> Void)? { get set }
    func register(_ hotKey: HotKey, for action: ShortcutAction) -> String?
    func unregisterAll()
}

@MainActor
public final class GlobalShortcutCoordinator {
    private let store: ShortcutStore
    private let registrar: any GlobalShortcutRegistering
    private var observation: AnyCancellable?
    private var activationObservation: AnyCancellable?
    private let onTrigger: (ShortcutAction) -> Void

    public convenience init(store: ShortcutStore = .shared, onTrigger: @escaping (ShortcutAction) -> Void) {
        self.init(store: store, registrar: CarbonShortcutRegistrar(), onTrigger: onTrigger)
    }

    init(store: ShortcutStore, registrar: any GlobalShortcutRegistering, onTrigger: @escaping (ShortcutAction) -> Void) {
        self.store = store
        self.registrar = registrar
        self.onTrigger = onTrigger
    }

    public func start() {
        guard observation == nil else { return }
        registrar.onTrigger = { [weak self] action in
            guard let self, self.store.recordingAction == nil, self.store.hotKey(for: action) != nil else { return }
            self.onTrigger(action)
        }
        activationObservation = NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification).sink { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.synchronize(hotKeys: self.store.hotKeys, recordingAction: self.store.recordingAction)
            }
        }
        observation = store.$hotKeys.combineLatest(store.$recordingAction).sink { [weak self] hotKeys, recordingAction in
            MainActor.assumeIsolated { self?.synchronize(hotKeys: hotKeys, recordingAction: recordingAction) }
        }
    }

    public func stop() {
        observation?.cancel()
        observation = nil
        activationObservation?.cancel()
        activationObservation = nil
        registrar.onTrigger = nil
        registrar.unregisterAll()
        store.setRegistrationErrors([:])
    }

    private func synchronize(hotKeys: [ShortcutAction: HotKey], recordingAction: ShortcutAction?) {
        registrar.unregisterAll()
        var errors: [ShortcutAction: String] = [:]
        if recordingAction == nil {
            for action in ShortcutAction.allCases where action.isGlobal {
                if let hotKey = hotKeys[action], let error = registrar.register(hotKey, for: action) { errors[action] = error }
            }
        }
        store.setRegistrationErrors(errors)
    }

}

private final class CarbonShortcutResources {
    var hotKeys: [EventHotKeyRef] = []
    var eventHandler: EventHandlerRef?
    var modifierMonitors: [Any] = []

    func unregisterAll() {
        for hotKey in hotKeys { UnregisterEventHotKey(hotKey) }
        hotKeys.removeAll()
        modifierMonitors.forEach(NSEvent.removeMonitor)
        modifierMonitors.removeAll()
        if let eventHandler { RemoveEventHandler(eventHandler) }
        eventHandler = nil
    }

    deinit { unregisterAll() }
}

@MainActor
private final class CarbonShortcutRegistrar: GlobalShortcutRegistering {
    var onTrigger: ((ShortcutAction) -> Void)?
    private let resources = CarbonShortcutResources()
    private static let signature: OSType = 0x41595343
    private var modifierChord = ModifierChord()

    func register(_ hotKey: HotKey, for action: ShortcutAction) -> String? {
        if hotKey.isModifierOnly {
            let consume: @Sendable (NSEvent) -> Void = { [weak self] event in
                let type = event.type
                let flags = event.modifierFlags
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if self.modifierChord.consume(type: type, flags: flags) { self.onTrigger?(action) }
                }
            }
            if let local = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown], handler: { event in consume(event); return event }) {
                resources.modifierMonitors.append(local)
            }
            if let global = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown], handler: consume) {
                resources.modifierMonitors.append(global)
            }
            if !AXIsProcessTrusted() { return AppLocalization.text("全局 ⌃⌥ 需要辅助功能权限，可在电脑操作设置中授权。") }
            return resources.modifierMonitors.isEmpty ? AppLocalization.text("无法监听应用快照快捷键") : nil
        }
        if resources.eventHandler == nil {
            var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let context = Unmanaged.passUnretained(self).toOpaque()
            let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
                guard let event, let context else { return OSStatus(eventNotHandledErr) }
                var identifier = EventHotKeyID()
                let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                               MemoryLayout<EventHotKeyID>.size, nil, &identifier)
                guard status == noErr, identifier.signature == CarbonShortcutRegistrar.signature,
                      identifier.id > 0, identifier.id <= ShortcutAction.allCases.count else {
                    return OSStatus(eventNotHandledErr)
                }
                let action = ShortcutAction.allCases[Int(identifier.id) - 1]
                MainActor.assumeIsolated {
                    Unmanaged<CarbonShortcutRegistrar>.fromOpaque(context).takeUnretainedValue().onTrigger?(action)
                }
                return noErr
            }, 1, &eventType, context, &resources.eventHandler)
            guard status == noErr else { return AppLocalization.text("无法监听全局快捷键（错误 %d）。", status) }
        }
        var reference: EventHotKeyRef?
        let identifier = EventHotKeyID(signature: Self.signature, id: UInt32(ShortcutAction.allCases.firstIndex(of: action)! + 1))
        let status = RegisterEventHotKey(hotKey.keyCode, hotKey.modifiers, identifier, GetApplicationEventTarget(), 0, &reference)
        guard status == noErr, let reference else {
            return AppLocalization.text("%@ 已被占用或无法注册（错误 %d）。请录制其他组合。", hotKey.label, status)
        }
        resources.hotKeys.append(reference)
        return nil
    }

    func unregisterAll() {
        modifierChord = ModifierChord()
        resources.unregisterAll()
    }
}

@MainActor
public extension View {
    func appShortcut(_ action: ShortcutAction, store: ShortcutStore = .shared) -> some View {
        modifier(AppShortcutModifier(action: action, store: store))
    }
}

@MainActor
private struct AppShortcutModifier: ViewModifier {
    let action: ShortcutAction
    @ObservedObject var store: ShortcutStore

    @ViewBuilder
    func body(content: Content) -> some View {
        if store.recordingAction == nil, let hotKey = store.hotKey(for: action), let equivalent = hotKey.keyEquivalent {
            content.keyboardShortcut(equivalent, modifiers: hotKey.eventModifiers)
        } else { content.keyboardShortcut(nil) }
    }
}

@MainActor
public struct ShortcutSettingsView: View {
    @Environment(\.locale) private var interfaceLocale
    @ObservedObject private var store: ShortcutStore

    public init(store: ShortcutStore = .shared) { self.store = store }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(AppLocalization.text("点击快捷键后按下新组合。按 Esc 取消录制；清除后仍可使用菜单或按钮。"))
                .font(.caption).foregroundStyle(.secondary)
            GroupBox(AppLocalization.text("全局快捷键 · 在任意应用中可用")) {
                rows(ShortcutAction.allCases.filter(\.isGlobal))
            }
            GroupBox(AppLocalization.text("应用内快捷键")) {
                rows(ShortcutAction.allCases.filter { !$0.isGlobal })
            }
            Button(AppLocalization.text("恢复全部默认快捷键")) { store.restoreDefaults() }
                .controlSize(.small)
        }
        .background(ShortcutRecordingMonitor(store: store).frame(width: 0, height: 0))
        .onDisappear { store.cancelRecording() }
    }

    private func rows(_ actions: [ShortcutAction]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(actions) { action in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(action.label(locale: interfaceLocale)).frame(maxWidth: .infinity, alignment: .leading)
                        Button(store.recordingAction == action ? AppLocalization.text("请按下组合键…") : store.label(for: action)) {
                            if store.recordingAction == action { store.cancelRecording() }
                            else { store.beginRecording(action) }
                        }
                        .frame(minWidth: 120).accessibilityLabel(AppLocalization.format("录制%@快捷键", locale: interfaceLocale, [action.label(locale: interfaceLocale)]))
                        Button(AppLocalization.text("清除")) { store.clear(action) }
                            .disabled(store.hotKey(for: action) == nil && store.recordingAction != action)
                    }
                    if store.recordingAction == action, let error = store.recordingError {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                    if let error = store.registrationErrors[action] {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                }
            }
        }
        .padding(8).controlSize(.small)
    }
}

@MainActor
private struct ShortcutRecordingMonitor: NSViewRepresentable {
    let store: ShortcutStore
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(store: store) }
    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) { coordinator.stop() }

    @MainActor
    final class Coordinator {
        private let store: ShortcutStore
        private var monitor: Any?
        private var resignObserver: NSObjectProtocol?

        init(store: ShortcutStore) {
            self.store = store
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak store] event in
                let consumed = MainActor.assumeIsolated {
                    guard let store, store.recordingAction != nil else { return false }
                    store.record(event)
                    return true
                }
                return consumed ? nil : event
            }
            resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: .main) { [weak store] _ in
                MainActor.assumeIsolated { store?.cancelRecording() }
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
            monitor = nil
            resignObserver = nil
            store.cancelRecording()
        }
    }
}


// 松开组合后再触发；组合期间输入其他按键时让出给系统和应用快捷键。
struct ModifierChord {
    private var armed = false
    private var cancelled = false

    static func normalized(_ flags: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
        flags.intersection([.control, .option, .command, .shift])
    }

    mutating func consume(type: NSEvent.EventType, flags: NSEvent.ModifierFlags) -> Bool {
        let flags = Self.normalized(flags)
        if type == .keyDown { cancelled = armed || !flags.isEmpty; armed = false; return false }
        guard type == .flagsChanged else { return false }
        if flags.isEmpty {
            let trigger = armed && !cancelled
            armed = false
            cancelled = false
            return trigger
        }
        if flags == [.control, .option], !cancelled { armed = true }
        if flags.contains(.command) || flags.contains(.shift) { cancelled = true; armed = false }
        return false
    }
}
