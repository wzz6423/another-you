import Foundation
import XCTest
@testable import AnotherYouCore

@MainActor
final class LocalModelSettingsTests: XCTestCase {
    private func status(model: String = "qwen3:4b") -> [String: JSONValue] {
        ["configured": .bool(true), "configuration": .object(["provider": .string("ollama"), "baseUrl": .string("http://127.0.0.1:11434"), "model": .string(model)]),
         "allowRemoteEscalation": .bool(false), "autoDraft": .bool(false)]
    }

    func testDraftSurvivesLegacyStatusUpdatesAndTestRequiresSavedConfiguration() {
        let session = LocalModelSettingsSession()
        var commands: [[String: JSONValue]] = []
        session.sendCommand = { commands.append($0); return true }
        session.canStartOperation = { true }
        session.updateConnection(true)
        session.update(status())
        XCTAssertFalse(session.hasUnsavedChanges)
        session.draft.model = "my-local-model"
        session.update(status())
        XCTAssertEqual(session.draft.model, "my-local-model")
        session.testConnection()
        XCTAssertTrue(commands.isEmpty)
        session.save()
        XCTAssertEqual(commands.last?["op"]?.string, "localModelConfigure")
        XCTAssertEqual(commands.last?["localModel"]?.object?["model"]?.string, "my-local-model")
        XCTAssertNil(commands.last?["allowRemoteEscalation"])
        XCTAssertNil(commands.last?["autoDraft"])
    }

    func testSaveWaitsForMatchingAcknowledgementAndClearsSecretOnlyOnSuccess() {
        let session = LocalModelSettingsSession()
        var command: [String: JSONValue] = [:]
        session.sendCommand = { command = $0; return true }
        session.canStartOperation = { true }
        session.updateConnection(true)
        session.update(status())
        session.draft.apiKey = "private-key"
        session.save()
        XCTAssertTrue(session.isBusy)
        func reply(_ id: String, state: String) -> AgentEvent {
            AgentEvent(id: UUID().uuidString, occurredAt: "2026-10-05T01:00:00Z", kind: "localModel.operation", source: "system",
                payload: ["requestId": .string(id), "operation": .string("localModelConfigure"), "state": .string(state)])
        }
        _ = session.consume(reply("stale", state: "succeeded"))
        XCTAssertTrue(session.isBusy)
        XCTAssertEqual(session.draft.apiKey, "private-key")
        _ = session.consume(reply(command["requestId"]!.string!, state: "succeeded"))
        XCTAssertFalse(session.isBusy)
        XCTAssertEqual(session.draft.apiKey, "")
        XCTAssertFalse(session.hasUnsavedChanges)
    }

    func testSwitchingServiceResetsModelAndDisconnectCancelsOperation() {
        let session = LocalModelSettingsSession()
        session.canStartOperation = { true }
        session.sendCommand = { _ in true }
        session.updateConnection(true)
        session.update(status())
        session.selectProvider("lmstudio")
        XCTAssertEqual(session.draft.baseUrl, "http://127.0.0.1:1234/v1")
        XCTAssertEqual(session.draft.model, "")
        session.loadModels()
        XCTAssertTrue(session.isBusy)
        session.updateConnection(false)
        XCTAssertFalse(session.isBusy)
        XCTAssertFalse(session.canChange)
    }

    func testAddressValidationRejectsCredentialsAndQueryTokens() {
        var draft = LocalModelDraft()
        XCTAssertTrue(draft.validAddress)
        for address in ["not a URL", "file:///tmp/model", "http://user:secret@localhost:1234", "http://localhost:1234?token=secret"] {
            draft.baseUrl = address
            XCTAssertFalse(draft.validAddress, address)
        }
    }

    func testWorkLookbackSelectionWaitsForReceiptAndKeepsSavedValueOnFailure() {
        let session = LocalModelSettingsSession()
        var commands: [[String: JSONValue]] = []
        session.canStartOperation = { true }
        session.sendCommand = { commands.append($0); return true }
        session.updateConnection(true)
        session.update(status())
        XCTAssertEqual(session.workLookbackHours, 24)
        session.selectWorkLookback(168)
        XCTAssertEqual(commands.last?["op"], .string("proactiveConfigure"))
        XCTAssertEqual(commands.last?["workLookbackHours"], .number(168))
        XCTAssertEqual(session.workLookbackHours, 24)
        func receipt(_ state: String) -> AgentEvent {
            AgentEvent(id: UUID().uuidString, occurredAt: "2026-10-07T01:00:00Z", kind: "localModel.operation", source: "system", payload: [
                "requestId": commands.last!["requestId"]!, "operation": .string("proactiveConfigure"), "state": .string(state), "workLookbackHours": .number(168)])
        }
        _ = session.consume(receipt("failed"))
        XCTAssertEqual(session.workLookbackHours, 24)
        session.selectWorkLookback(168)
        _ = session.consume(receipt("succeeded"))
        XCTAssertEqual(session.workLookbackHours, 168)
        session.selectWorkLookback(48)
        XCTAssertEqual(commands.count, 2)
        session.update(status().merging(["workLookbackHours": .number(720)]) { _, new in new })
        XCTAssertEqual(session.workLookbackHours, 720)
    }
}
