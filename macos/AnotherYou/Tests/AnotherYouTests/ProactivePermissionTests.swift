import AppKit
import Foundation
import UserNotifications
import XCTest
@testable import AnotherYouCore

@MainActor
private final class PermissionClient: AgentClient {
    var onMessage: (@MainActor @Sendable (AgentClientMessage) -> Void)?
    func start(configURL: URL) throws {}
    func send(_ command: [String: JSONValue]) throws {}
    func stop() async { onMessage?(.connection(.stopped)) }

    func status(paused: Bool = false, schedulerEnabled: Bool = true, proactiveEnabled: Bool = true) {
        onMessage?(.connection(.connected))
        onMessage?(.event(AgentEvent(id: UUID().uuidString, occurredAt: ISO8601DateFormatter().string(from: Date()), kind: "agent.status", source: "agent", payload: [
            "paused": .bool(paused), "schedulerEnabled": .bool(schedulerEnabled),
            "proactive": .object(["enabled": .bool(proactiveEnabled)]),
        ])))
    }
}

@MainActor
private final class PermissionFixture: ProactivePermissionAuthorizing {
    var supported = true
    var canPresentPrompt = true
    var accessibilityGranted = false
    var authorization: UNAuthorizationStatus = .notDetermined
    var notificationsGranted = true
    var notificationError: Error?
    var suspendNotificationCheck = false
    var pendingCheck: CheckedContinuation<UNAuthorizationStatus, Never>?
    var suspendNotificationRequest = false
    var pendingRequest: CheckedContinuation<Bool, Never>?
    var notificationChecks = 0
    var notificationRequests = 0
    var accessibilityRequests = 0

    func requestAccessibility() async throws { accessibilityRequests += 1 }
    func notificationAuthorization() async -> UNAuthorizationStatus {
        notificationChecks += 1
        if suspendNotificationCheck {
            return await withCheckedContinuation { pendingCheck = $0 }
        }
        return authorization
    }
    func requestNotifications() async throws -> Bool {
        notificationRequests += 1
        if let notificationError { throw notificationError }
        if suspendNotificationRequest {
            return await withCheckedContinuation { pendingRequest = $0 }
        }
        authorization = notificationsGranted ? .authorized : .denied
        return notificationsGranted
    }
}

@MainActor
final class ProactivePermissionTests: XCTestCase {
    private func withStore(_ body: @MainActor (AssistantStore, PermissionClient, PermissionFixture, UserDefaults) async throws -> Void) async throws {
        let name = "another-you-permissions-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        defer { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: directory) }
        let client = PermissionClient()
        let permissions = PermissionFixture()
        let store = AssistantStore(client: client, repository: AgentSettingsRepository(dataDirectory: directory), defaults: defaults, proactivePermissions: permissions)
        try await body(store, client, permissions, defaults)
        await store.shutdown()
    }

    private func settle() async {
        for _ in 0..<30 { await Task.yield() }
    }

    func testNewUserDefaultsOnAndRequestsOnlyNecessaryPermissionsOnce() async throws {
        try await withStore { store, client, permissions, defaults in
            XCTAssertTrue(store.notificationsEnabled)
            client.status()
            await settle()
            XCTAssertEqual(permissions.notificationRequests, 1)
            XCTAssertEqual(permissions.accessibilityRequests, 1)
            XCTAssertTrue(store.notificationsEnabled)
            XCTAssertNil(store.notificationMessage)
            XCTAssertTrue(defaults.bool(forKey: "proactiveAccessibilityRequested"))
            client.status()
            NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
            await settle()
            XCTAssertEqual(permissions.notificationRequests, 1)
            XCTAssertEqual(permissions.accessibilityRequests, 1)
        }
    }

    func testPreviouslyDisabledNotificationsAndRequestedAccessibilityStayDisabled() async throws {
        try await withStore { store, client, permissions, defaults in
            await store.setNotificationsEnabled(false)
            defaults.set(true, forKey: "proactiveAccessibilityRequested")
            client.status()
            await settle()
            XCTAssertFalse(store.notificationsEnabled)
            XCTAssertEqual(permissions.notificationChecks, 0)
            XCTAssertEqual(permissions.accessibilityRequests, 0)
            let restored = AssistantStore(client: PermissionClient(), defaults: defaults, proactivePermissions: permissions)
            XCTAssertFalse(restored.notificationsEnabled)
            await restored.shutdown()
        }
    }

    func testInactiveOrDisabledProactiveSessionDoesNotPromptUntilResumed() async throws {
        try await withStore { _, client, permissions, _ in
            permissions.canPresentPrompt = false
            client.status()
            await settle()
            XCTAssertEqual(permissions.notificationChecks, 0)
            permissions.canPresentPrompt = true
            client.status(paused: true)
            await settle()
            client.status(schedulerEnabled: false)
            await settle()
            client.status(proactiveEnabled: false)
            await settle()
            XCTAssertEqual(permissions.notificationChecks, 0)
            XCTAssertEqual(permissions.accessibilityRequests, 0)
            client.status()
            await settle()
            XCTAssertEqual(permissions.notificationRequests, 1)
            XCTAssertEqual(permissions.accessibilityRequests, 1)
        }
    }

    func testApplicationActivationRequestsDeferredPermissions() async throws {
        try await withStore { _, client, permissions, _ in
            permissions.canPresentPrompt = false
            client.status()
            await settle()
            permissions.canPresentPrompt = true
            NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
            await settle()
            XCTAssertEqual(permissions.notificationRequests, 1)
            XCTAssertEqual(permissions.accessibilityRequests, 1)
        }
    }

    func testDeniedNotificationsRemainExplicitAndDoNotRequestAgain() async throws {
        try await withStore { store, client, permissions, defaults in
            permissions.authorization = .denied
            client.status()
            await settle()
            XCTAssertFalse(store.notificationsEnabled)
            XCTAssertNotNil(store.notificationMessage)
            XCTAssertFalse(defaults.bool(forKey: "notificationsEnabled"))
            await store.setNotificationsEnabled(true)
            XCTAssertFalse(store.notificationsEnabled)
            XCTAssertEqual(permissions.notificationRequests, 0)
        }
    }

    func testDecliningFirstNotificationPromptIsPersistedWithoutRepeating() async throws {
        try await withStore { store, client, permissions, defaults in
            permissions.notificationsGranted = false
            client.status()
            await settle()
            XCTAssertFalse(store.notificationsEnabled)
            XCTAssertFalse(defaults.bool(forKey: "notificationsEnabled"))
            client.status()
            await settle()
            XCTAssertEqual(permissions.notificationRequests, 1)
            XCTAssertEqual(permissions.accessibilityRequests, 1)
        }
    }

    func testExistingGrantsAndUnsupportedExecutableDoNotPrompt() async throws {
        try await withStore { _, client, permissions, _ in
            permissions.supported = false
            client.status()
            await settle()
            XCTAssertEqual(permissions.notificationChecks, 0)
            XCTAssertEqual(permissions.accessibilityRequests, 0)
            permissions.supported = true
            permissions.authorization = .authorized
            permissions.accessibilityGranted = true
            client.status()
            await settle()
            XCTAssertEqual(permissions.notificationRequests, 0)
            XCTAssertEqual(permissions.accessibilityRequests, 0)
        }
    }

    func testNotificationRequestErrorDisablesPreferenceWithActionableLocalizedMessage() async throws {
        try await withStore { store, client, permissions, defaults in
            permissions.notificationError = NSError(domain: UNErrorDomain, code: UNError.Code.notificationsNotAllowed.rawValue,
                userInfo: [NSLocalizedDescriptionKey: "Notifications are not allowed for this application"])
            client.status()
            await settle()
            XCTAssertFalse(store.notificationsEnabled)
            XCTAssertFalse(defaults.bool(forKey: "notificationsEnabled"))
            XCTAssertEqual(store.notificationMessage, "通知权限未开启，可前往 macOS 系统设置调整。")
            client.status()
            await settle()
            XCTAssertEqual(permissions.notificationRequests, 1)
        }
    }

    func testUserTurningNotificationsOffWhilePromptIsPendingWins() async throws {
        try await withStore { store, client, permissions, defaults in
            permissions.suspendNotificationRequest = true
            client.status()
            await settle()
            XCTAssertEqual(permissions.notificationRequests, 1)
            await store.setNotificationsEnabled(false)
            permissions.pendingRequest?.resume(returning: true)
            permissions.pendingRequest = nil
            await settle()
            XCTAssertFalse(store.notificationsEnabled)
            XCTAssertFalse(defaults.bool(forKey: "notificationsEnabled"))
        }
    }

    func testAutomaticPromptRechecksSessionAfterAwaitingAuthorization() async throws {
        for boundary in ["paused", "disconnected", "inactive", "scheduler", "proactive"] {
            try await withStore { _, client, permissions, defaults in
                permissions.suspendNotificationCheck = true
                client.status()
                await settle()
                XCTAssertNotNil(permissions.pendingCheck, boundary)
                switch boundary {
                case "paused": client.status(paused: true)
                case "disconnected": client.onMessage?(.connection(.stopped))
                case "inactive": permissions.canPresentPrompt = false
                case "scheduler": client.status(schedulerEnabled: false)
                default: client.status(proactiveEnabled: false)
                }
                permissions.suspendNotificationCheck = false
                permissions.pendingCheck?.resume(returning: .notDetermined)
                permissions.pendingCheck = nil
                await settle()
                XCTAssertEqual(permissions.notificationRequests, 0, boundary)
                XCTAssertEqual(permissions.accessibilityRequests, 0, boundary)
                XCTAssertFalse(defaults.bool(forKey: "proactiveAccessibilityRequested"), boundary)
                permissions.canPresentPrompt = true
                client.status()
                await settle()
                XCTAssertEqual(permissions.notificationRequests, 1, boundary)
                XCTAssertEqual(permissions.accessibilityRequests, 1, boundary)
            }
        }
    }

    func testShutdownIgnoresPendingPermissionResultAndDoesNotRequestAccessibility() async throws {
        try await withStore { store, client, permissions, defaults in
            permissions.suspendNotificationRequest = true
            client.status()
            await settle()
            XCTAssertEqual(permissions.notificationRequests, 1)
            await store.shutdown()
            permissions.pendingRequest?.resume(returning: false)
            permissions.pendingRequest = nil
            await settle()
            XCTAssertTrue(store.notificationsEnabled)
            XCTAssertNil(store.notificationMessage)
            XCTAssertEqual(permissions.accessibilityRequests, 0)
            XCTAssertFalse(defaults.bool(forKey: "proactiveAccessibilityRequested"))
        }
    }
}
