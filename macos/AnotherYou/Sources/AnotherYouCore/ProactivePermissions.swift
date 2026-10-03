import AppKit
import Foundation
import UserNotifications

@MainActor
public protocol ProactivePermissionAuthorizing {
    var supported: Bool { get }
    var canPresentPrompt: Bool { get }
    var accessibilityGranted: Bool { get }
    func requestAccessibility() async throws
    func notificationAuthorization() async -> UNAuthorizationStatus
    func requestNotifications() async throws -> Bool
}

@MainActor
public final class SystemProactivePermissions: ProactivePermissionAuthorizing {
    private let desktop = DesktopAutomation()

    public init() {}

    public var supported: Bool {
        Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil
    }

    public var canPresentPrompt: Bool { NSApplication.shared.isActive }

    public var accessibilityGranted: Bool { desktop.capabilities["accessibilityGranted"]?.bool == true }

    public func requestAccessibility() async throws {
        _ = try await desktop.handle(["action": .string("requestPermissions"), "permission": .string("accessibility")])
    }

    public func notificationAuthorization() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    public func requestNotifications() async throws -> Bool {
        try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }
}
