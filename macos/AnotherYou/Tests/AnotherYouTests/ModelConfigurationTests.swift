import Foundation
import Testing
@testable import AnotherYouCore

@MainActor
struct ModelConfigurationTests {
    private func event(_ kind: String, _ payload: [String: JSONValue]) -> AgentEvent {
        AgentEvent(id: UUID().uuidString, occurredAt: "2026-10-02T00:00:00Z", kind: kind, source: "system", payload: payload)
    }

    private func session() -> ModelConfigurationSession {
        let session = ModelConfigurationSession()
        session.updateConnection(connected: true, busy: false)
        session.canStartOperation = { true }
        return session
    }

    private func model(_ id: String = "alpha", provider: String = "fixture") -> PiModelOption {
        PiModelOption(modelID: id, name: id.capitalized, provider: provider, input: ["text", "image"], thinkingLevels: ["off", "high"], contextWindow: 4096, maxTokens: 1024, configured: true)
    }

    @Test func catalogSearchIncludesUnauthenticatedProvidersAndCapabilities() throws {
        var catalog = PiModelCatalog()
        catalog.models = [model(), model("beta", provider: "other")]
        #expect(catalog.filteredModels(query: " ALPHA ", provider: "").map(\.modelID) == ["alpha"])
        #expect(catalog.filteredModels(query: "other", provider: "other").map(\.modelID) == ["beta"])
        #expect(catalog.filteredModels(query: "alpha", provider: "other").isEmpty)
        #expect(catalog.models.first?.supportsImages == true)
        #expect(try JSONDecoder().decode(PiModelCatalog.self, from: JSONEncoder().encode(catalog)) == catalog)
    }

    @Test func selectionWaitsForMatchingReceiptAndBusyRuntimeRejectsEdits() {
        let session = session()
        var sent: [[String: JSONValue]] = []
        session.sendCommand = { sent.append($0); return true }
        session.select(model(), thinkingLevel: "high")
        let requestID = sent[0]["requestId"]!
        #expect(session.isBusy)
        #expect(session.catalog.selected == nil)
        #expect(sent[0]["thinkingLevel"] == .string("high"))
        _ = session.consume(event("model.operation", ["requestId": .string("stale"), "operation": .string("modelSelect"), "state": .string("succeeded")]))
        #expect(session.isBusy)
        _ = session.consume(event("model.operation", ["requestId": requestID, "operation": .string("modelSelect"), "state": .string("succeeded")]))
        #expect(!session.isBusy)
        session.updateConnection(connected: true, busy: true)
        session.select(model(), thinkingLevel: "off")
        #expect(sent.count == 1)
    }

    @Test func catalogFailureAndRefreshReceiptsReleaseLoadingState() {
        let session = session()
        var sent: [[String: JSONValue]] = []
        session.sendCommand = { sent.append($0); return true }
        session.loadCatalog()
        #expect(session.isLoading)
        let id = sent[0]["requestId"]!
        _ = session.consume(event("agent.error", ["requestId": id, "message": .string("invalid command")]))
        #expect(!session.isLoading)
        session.refreshCatalog()
        #expect(sent.last?["refresh"] == .bool(true))
        _ = session.consume(event("model.operation", ["requestId": sent.last!["requestId"]!, "operation": .string("modelCatalog"), "state": .string("failed"), "message": .string("刷新失败")]))
        #expect(!session.isBusy)
        #expect(session.message == "刷新失败")
    }

    @Test func apiKeyReplyUsesPromptIdentityAndRemainsPendingUntilAcknowledged() {
        let session = session()
        var sent: [[String: JSONValue]] = []
        session.sendCommand = { sent.append($0); return true }
        session.login(provider: "fixture", type: "api_key")
        let requestID = sent[0]["requestId"]!
        _ = session.consume(event("model.auth", ["requestId": requestID, "provider": .string("fixture"), "stage": .string("prompt"),
            "prompt": .object(["id": .string("prompt-1"), "type": .string("secret"), "message": .string("API key")])]))
        #expect(session.answer("fixture-key"))
        #expect(sent.last?["promptId"] == .string("prompt-1"))
        #expect(session.authentication?.prompt?.id == "prompt-1")
        _ = session.consume(event("model.auth", ["requestId": requestID, "provider": .string("fixture"), "stage": .string("promptResolved"), "promptId": .string("old")]))
        #expect(session.authentication?.prompt != nil)
        _ = session.consume(event("model.auth", ["requestId": requestID, "provider": .string("fixture"), "stage": .string("promptResolved"), "promptId": .string("prompt-1")]))
        #expect(session.authentication?.prompt == nil)
        _ = session.consume(event("model.operation", ["requestId": requestID, "operation": .string("modelLogin"), "state": .string("succeeded")]))
        #expect(session.authentication == nil)
        #expect(!session.isBusy)
    }

    @Test func oauthCancellationAndDisconnectRemoveTransientAuthentication() {
        let session = session()
        var sent: [[String: JSONValue]] = []
        session.sendCommand = { sent.append($0); return true }
        session.login(provider: "fixture", type: "oauth")
        let requestID = sent[0]["requestId"]!
        _ = session.consume(event("model.auth", ["requestId": requestID, "provider": .string("fixture"), "stage": .string("notify"),
            "notice": .object(["type": .string("device_code"), "userCode": .string("A-B"), "verificationUri": .string("https://example.invalid")])]))
        #expect(session.authentication?.notices.first?.userCode == "A-B")
        session.cancel()
        #expect(sent.last?["op"] == .string("modelAuthCancel"))
        #expect(session.isBusy)
        _ = session.consume(event("model.operation", ["requestId": requestID, "operation": .string("modelLogin"), "state": .string("cancelled")]))
        #expect(session.authentication == nil)
        session.login(provider: "fixture", type: "oauth")
        session.updateConnection(connected: false, busy: false)
        #expect(!session.isBusy && !session.isConnected)
        #expect(session.authentication == nil)
    }

    @Test func malformedAuthenticationCancelsBackendAndAllowsRecovery() {
        let session = session()
        var sent: [[String: JSONValue]] = []
        session.sendCommand = { sent.append($0); return true }
        session.login(provider: "fixture", type: "oauth")
        let requestID = sent[0]["requestId"]!
        _ = session.consume(event("model.auth", ["requestId": requestID, "provider": .string("fixture"), "stage": .string("prompt"),
            "prompt": .object(["id": .string("p"), "type": .string("select"), "message": .string("Choose")])]))
        #expect(sent.last?["op"] == .string("modelAuthCancel"))
        #expect(session.authentication == nil)
        #expect(!session.isBusy)
        #expect(session.message == "模型配置响应无效，请重新操作")
        session.login(provider: "fixture", type: "oauth")
        #expect(session.isBusy)
    }

    @Test func sendFailuresDoNotClaimAuthenticationOrCancellationSucceeded() {
        let session = session()
        session.sendCommand = { _ in false }
        session.login(provider: "fixture", type: "api_key")
        #expect(!session.isBusy)
        #expect(session.authentication == nil)
        var command: [String: JSONValue] = [:]
        session.sendCommand = { command = $0; return true }
        session.login(provider: "fixture", type: "api_key")
        _ = session.consume(event("model.auth", ["requestId": command["requestId"]!, "provider": .string("fixture"), "stage": .string("prompt"),
            "prompt": .object(["id": .string("p"), "type": .string("secret"), "message": .string("Key")])]))
        session.sendCommand = { _ in false }
        #expect(!session.answer("key"))
        #expect(session.authentication?.prompt != nil)
        session.cancel()
        #expect(session.isBusy)
        #expect(session.message == "取消命令发送失败，请重试")
    }

    @Test func failedAuthReplyDoesNotEndOriginalLogin() {
        let session = session()
        var command: [String: JSONValue] = [:]
        session.sendCommand = { command = $0; return true }
        session.login(provider: "fixture", type: "api_key")
        _ = session.consume(event("model.operation", ["requestId": command["requestId"]!, "operation": .string("modelAuthReply"), "state": .string("failed"), "message": .string("认证输入已失效")]))
        #expect(session.isBusy)
        #expect(session.authentication != nil)
        #expect(session.message == "认证输入已失效")
    }
}
