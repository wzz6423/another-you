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

    private func accountCatalog(_ id: String = "account-a") -> AgentEvent {
        event("model.catalog", ["models": .array([]), "providers": .array([.object([
            "id": .string("fixture"), "name": .string("Fixture"), "configured": .bool(true), "accountId": .string(id),
            "credentialType": .string("api_key"), "authMethods": .array([]),
            "apiConfiguration": .object(["baseUrl": .string("https://example.invalid/" + id), "api": .string("openai-completions")])])]),
            "accounts": .array(["account-a", "account-b"].map { .object(["id": .string($0), "provider": .string("fixture"),
                "name": .string($0), "hasAPIKey": .bool(true), "credentialType": .string("api_key")]) }),
            "selected": .object(["provider": .string("fixture"), "model": .string(id), "thinkingLevel": .string("high")])])
    }

    @Test func savedKeyOnlyRevealsOnMatchingRequestAndNeverOverwritesEdits() {
        let session = session()
        var sent: [[String: JSONValue]] = []
        session.sendCommand = { sent.append($0); return true }
        _ = session.consume(accountCatalog())
        session.accountProviderID = "fixture"
        session.prepareAPIConfiguration(provider: "fixture")
        #expect(session.hasSavedAPIKey && session.revealedAPIKey.isEmpty && !session.isAPIKeyVisible)
        session.toggleAPIKeyVisibility()
        let request = sent.last!
        #expect(request["op"] == .string("modelCredentialRead"))
        func reply(_ id: JSONValue, account: String = "account-a") -> AgentEvent {
            event("model.credential", ["requestId": id, "accountId": .string(account), "apiKey": .string("saved-key")])
        }
        _ = session.consume(reply(.string("old")))
        _ = session.consume(reply(request["requestId"]!, account: "account-b"))
        #expect(session.revealedAPIKey.isEmpty)
        _ = session.consume(reply(request["requestId"]!))
        #expect(session.revealedAPIKey == "saved-key" && session.apiConfigurationDraft.apiKey.isEmpty)
        session.toggleAPIKeyVisibility()
        #expect(session.revealedAPIKey.isEmpty && !session.isAPIKeyVisible)
        session.toggleAPIKeyVisibility()
        let pending = sent.last!["requestId"]!
        session.editAPIKey("new-key")
        _ = session.consume(reply(pending))
        #expect(session.apiConfigurationDraft.apiKey == "new-key" && session.revealedAPIKey.isEmpty)
        session.clearAPIKey()
        _ = session.consume(reply(pending))
        #expect(session.apiConfigurationDraft.apiKey.isEmpty && session.revealedAPIKey.isEmpty && !session.isAPIKeyVisible)
        session.toggleAPIKeyVisibility()
        let disconnected = sent.last!["requestId"]!
        session.updateConnection(connected: false, busy: false)
        _ = session.consume(reply(disconnected))
        #expect(session.revealedAPIKey.isEmpty && !session.isAPIKeyVisible)
    }

    @Test func accountSwitchWaitsForReceiptRestoresFormAndRejectsPreviousKey() {
        let session = session()
        var sent: [[String: JSONValue]] = []
        session.sendCommand = { sent.append($0); return true }
        _ = session.consume(accountCatalog())
        session.accountProviderID = "fixture"
        session.prepareAPIConfiguration(provider: "fixture")
        session.toggleAPIKeyVisibility()
        let oldRequest = sent.last!["requestId"]!
        session.selectAccount("account-b")
        #expect(session.activeAccountID == "account-a" && session.isBusy)
        #expect(sent.last?["op"] == .string("modelAccountSelect"))
        _ = session.consume(accountCatalog("account-b"))
        session.prepareAPIConfiguration(provider: "fixture")
        _ = session.consume(event("model.credential", ["requestId": oldRequest, "accountId": .string("account-a"), "apiKey": .string("old-key")]))
        #expect(session.activeAccountID == "account-b" && session.accountName == "account-b")
        #expect(session.apiConfigurationDraft.baseUrl == "https://example.invalid/account-b")
        #expect(session.apiConfigurationDraft.model == "account-b" && session.revealedAPIKey.isEmpty)
        _ = session.consume(event("model.operation", ["requestId": sent.last!["requestId"]!, "operation": .string("modelAccountSelect"), "state": .string("succeeded")]))
        session.newAccount()
        #expect(session.isNewAccount && !session.hasSavedAPIKey && session.accountName.isEmpty)
        session.apiConfigurationDraft.model = "unsaved-new-model"
        session.selectAccount("account-b")
        #expect(!session.isNewAccount && session.apiConfigurationDraft.model == "account-b")
        #expect(session.catalog.selected?.thinkingLevel == "high")
        session.newAccount()
        session.accountName = "Account C"
        session.editAPIKey("new-account-key")
        session.configureAPI(thinkingLevel: "off")
        #expect(sent.last?["newAccount"] == .bool(true) && sent.last?["accountId"] == nil)
        #expect(sent.last?["accountName"] == .string("Account C"))
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

    @Test func piImportUsesAutomaticDiscoveryAndWaitsForMatchingReceipt() {
        let session = session()
        var sent: [[String: JSONValue]] = []
        session.sendCommand = { sent.append($0); return true }
        session.importConfiguration()
        #expect(sent.count == 1)
        #expect(sent[0]["op"] == .string("modelImport"))
        #expect(sent[0]["path"] == nil)
        #expect(session.isBusy)
        session.importConfiguration()
        #expect(sent.count == 1)
        _ = session.consume(event("model.operation", ["requestId": .string("stale"), "operation": .string("modelImport"), "state": .string("succeeded")]))
        #expect(session.isBusy)
        _ = session.consume(event("model.operation", ["requestId": sent[0]["requestId"]!, "operation": .string("modelImport"), "state": .string("failed"), "message": .string("未找到 Pi 模型配置")]))
        #expect(session.message == "未找到 Pi 模型配置")
        #expect(session.canChange)
    }

    @Test func apiConfigurationCatalogDecodesWithoutExposingCredentials() throws {
        let data = Data(#"{"models":[],"providers":[{"id":"openai","name":"OpenAI","configured":false,"authMethods":[{"type":"api_key","name":"API key"}],"apiConfiguration":{"baseUrl":"https://api.openai.com/v1","api":"openai-responses"}}]}"#.utf8)
        let catalog = try JSONDecoder().decode(PiModelCatalog.self, from: data)
        #expect(catalog.providers[0].apiConfiguration?.baseUrl == "https://api.openai.com/v1")
        #expect(catalog.providers[0].apiConfiguration?.api == "openai-responses")
        let legacy = Data(#"{"id":"fixture","name":"Fixture","configured":false,"authMethods":[]}"#.utf8)
        #expect(try JSONDecoder().decode(PiProviderOption.self, from: legacy).apiConfiguration == nil)
    }

    @Test func apiFormKeepsDraftAndSendsCompleteConfigurationUntilMatchingReceipt() {
        let session = session()
        var sent: [[String: JSONValue]] = []
        session.sendCommand = { sent.append($0); return true }
        session.prepareAPIConfiguration(provider: nil)
        session.apiConfigurationDraft.baseUrl = " https://api.example.com/v1 "
        session.apiConfigurationDraft.model = " gateway-model "
        session.apiConfigurationDraft.apiKey = " fixture-api-key "
        session.prepareAPIConfiguration(provider: nil)
        #expect(session.apiConfigurationDraft.apiKey == " fixture-api-key ")
        session.configureAPI(thinkingLevel: "off")
        #expect(sent[0]["op"] == .string("modelConfigure"))
        #expect(sent[0]["provider"] == .string("custom"))
        #expect(sent[0]["baseUrl"] == .string("https://api.example.com/v1"))
        #expect(sent[0]["api"] == .string("openai-completions"))
        #expect(sent[0]["model"] == .string("gateway-model"))
        #expect(sent[0]["apiKey"] == .string("fixture-api-key"))
        #expect(session.isBusy && session.catalog.selected == nil)
        session.configureAPI(thinkingLevel: "off")
        #expect(sent.count == 1)
        _ = session.consume(event("model.operation", ["requestId": .string("stale"), "operation": .string("modelConfigure"), "state": .string("succeeded")]))
        #expect(!session.apiConfigurationDraft.apiKey.isEmpty)
        _ = session.consume(event("model.operation", ["requestId": sent[0]["requestId"]!, "operation": .string("modelConfigure"), "state": .string("succeeded")]))
        #expect(!session.isBusy && session.apiConfigurationDraft.apiKey.isEmpty)
        #expect(session.apiConfigurationDraft.model == " gateway-model ")
    }

    @Test func reopeningCustomFormPreservesProviderAndDraftWithAnotherSavedModel() {
        let session = session()
        let snapshot: [String: JSONValue] = ["models": .array([]), "providers": .array([.object([
            "id": .string("openai"), "name": .string("OpenAI"), "configured": .bool(true),
            "authMethods": .array([])])]), "selected": .object([
                "provider": .string("openai"), "model": .string("saved"), "thinkingLevel": .string("off")])]
        _ = session.consume(event("model.catalog", snapshot))
        session.synchronizeProvider()
        #expect(session.accountProviderID == "openai")
        session.accountProviderID = ModelConfigurationSession.customProviderID
        session.prepareAPIConfiguration(provider: nil)
        session.apiConfigurationDraft.baseUrl = "https://api.example.com/v1"
        session.apiConfigurationDraft.model = "draft-model"
        session.apiConfigurationDraft.apiKey = "draft-key"
        let draft = session.apiConfigurationDraft
        _ = session.consume(event("model.catalog", snapshot))
        session.synchronizeProvider()
        session.prepareAPIConfiguration(provider: nil)
        #expect(session.accountProviderID == ModelConfigurationSession.customProviderID)
        #expect(session.apiConfigurationDraft == draft)
        session.synchronizeProvider(preferSavedSelection: true)
        #expect(session.accountProviderID == "openai")
    }

    @Test func apiFormRequiresCompleteFieldsAndOnlyRetainsSavedAPIKeyAccounts() {
        let session = session()
        var sent: [[String: JSONValue]] = []
        session.sendCommand = { sent.append($0); return true }
        session.apiConfigurationDraft = PiAPIConfigurationDraft(provider: "fixture", baseUrl: "https://api.example.com/v1", model: "test")
        session.configureAPI(thinkingLevel: "off")
        #expect(sent.isEmpty)
        func account(_ credential: String) -> AgentEvent {
            event("model.catalog", ["models": .array([]), "providers": .array([.object([
                "id": .string("fixture"), "name": .string("Fixture"), "configured": .bool(true),
                "credentialType": .string(credential), "authMethods": .array([]),
                "apiConfiguration": .object(["baseUrl": .string("https://api.example.com/v1"), "api": .string("openai-completions")])])])])
        }
        _ = session.consume(account("oauth"))
        #expect(!session.hasSavedAPIKey)
        session.configureAPI(thinkingLevel: "off")
        #expect(sent.isEmpty)
        _ = session.consume(account("api_key"))
        #expect(session.hasSavedAPIKey)
        session.apiConfigurationDraft.baseUrl = "file:///tmp/fixture"
        session.configureAPI(thinkingLevel: "off")
        #expect(sent.isEmpty)
        session.apiConfigurationDraft.baseUrl = "https://user:password@api.example.com/v1"
        session.configureAPI(thinkingLevel: "off")
        #expect(sent.isEmpty)
        session.apiConfigurationDraft.baseUrl = "https://api.example.com/v1"
        session.configureAPI(thinkingLevel: "off")
        #expect(sent.count == 1 && sent[0]["apiKey"] == nil)
    }

    @Test func failedAPISaveAllowsRetryAndDisconnectionClearsTheKey() {
        let session = session()
        var sent: [[String: JSONValue]] = []
        session.sendCommand = { sent.append($0); return true }
        session.apiConfigurationDraft = PiAPIConfigurationDraft(provider: "fixture", baseUrl: "https://api.example.com/v1", model: "test", apiKey: "retry-key")
        session.configureAPI(thinkingLevel: "off")
        _ = session.consume(event("model.operation", ["requestId": sent[0]["requestId"]!, "operation": .string("modelConfigure"), "state": .string("failed"), "message": .string("保存失败")]))
        #expect(session.apiConfigurationDraft.apiKey == "retry-key" && session.canChange)
        session.configureAPI(thinkingLevel: "off")
        #expect(sent.count == 2)
        session.updateConnection(connected: false, busy: false)
        #expect(session.apiConfigurationDraft.apiKey.isEmpty && !session.isBusy)
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
        #expect(session.isSubmittingAuthentication)
        #expect(!session.answer("duplicate-key"))
        #expect(sent.count == 2)
        _ = session.consume(event("model.auth", ["requestId": requestID, "provider": .string("fixture"), "stage": .string("promptResolved"), "promptId": .string("old")]))
        #expect(session.authentication?.prompt != nil)
        #expect(session.isSubmittingAuthentication)
        _ = session.consume(event("model.auth", ["requestId": requestID, "provider": .string("fixture"), "stage": .string("promptResolved"), "promptId": .string("prompt-1")]))
        #expect(session.authentication?.prompt == nil)
        #expect(!session.isSubmittingAuthentication)
        _ = session.consume(event("model.operation", ["requestId": requestID, "operation": .string("modelLogin"), "state": .string("succeeded")]))
        #expect(session.authentication == nil)
        #expect(!session.isBusy)
    }

    @Test func copilotDomainCanBeEmptyAndCancellationAllowsAnotherProvider() {
        let session = session()
        var sent: [[String: JSONValue]] = []
        session.sendCommand = { sent.append($0); return true }
        session.login(provider: "github-copilot", type: "oauth")
        let requestID = sent[0]["requestId"]!
        _ = session.consume(event("model.auth", ["requestId": requestID, "provider": .string("github-copilot"), "stage": .string("prompt"),
            "prompt": .object(["id": .string("domain"), "type": .string("text"), "message": .string("GitHub Enterprise URL/domain (blank for github.com)")])]))
        #expect(session.canAnswerAuthentication(""))
        #expect(session.answer(""))
        #expect(sent.last?["value"] == .string(""))
        #expect(!session.canAnswerAuthentication(""))
        _ = session.consume(event("model.auth", ["requestId": requestID, "provider": .string("github-copilot"), "stage": .string("promptResolved"), "promptId": .string("domain")]))
        _ = session.consume(event("model.auth", ["requestId": requestID, "provider": .string("github-copilot"), "stage": .string("notify"),
            "notice": .object(["type": .string("device_code"), "userCode": .string("ABCD-EFGH"), "verificationUri": .string("https://github.com/login/device")])]))
        #expect(session.authentication?.notices.last?.userCode == "ABCD-EFGH")
        #expect(!session.canAnswerAuthentication(""))
        session.cancel()
        _ = session.consume(event("model.operation", ["requestId": requestID, "operation": .string("modelLogin"), "state": .string("cancelled")]))
        #expect(session.canChange)
        session.login(provider: "other", type: "api_key")
        #expect(session.authentication?.provider == "other")
        #expect(session.authentication?.prompt == nil)
        #expect(session.authentication?.notices.isEmpty == true)
    }

    @Test(arguments: ["text", "secret", "manual_code", "select"])
    func authenticationValidatesInputBeforeSending(type: String) {
        let session = session()
        var sent: [[String: JSONValue]] = []
        session.sendCommand = { sent.append($0); return true }
        session.login(provider: "fixture", type: "oauth")
        _ = session.consume(event("model.auth", ["requestId": sent[0]["requestId"]!, "provider": .string("fixture"), "stage": .string("prompt"),
            "prompt": .object(["id": .string("input"), "type": .string(type), "message": .string("Input"),
                               "options": .array([.object(["id": .string("valid"), "label": .string("Valid")])])])]))
        #expect(!session.answer(String(repeating: "a", count: 8193)))
        #expect(!session.answer(String(repeating: "😀", count: 4097)))
        #expect(session.canAnswerAuthentication("") == (type == "text"))
        #expect(session.canAnswerAuthentication(" \n\t") == (type == "text"))
        if type == "select" { #expect(!session.answer("invalid-option")) }
        if type != "text" { #expect(!session.answer(" \n\t")) }
        #expect(sent.count == 1)
        #expect(session.answer("valid"))
        #expect(sent.last?["value"] == .string("valid"))
    }

    @Test func rejectedAuthenticationInputCanBeRetriedWithoutRestartingLogin() {
        let session = session()
        var sent: [[String: JSONValue]] = []
        session.sendCommand = { sent.append($0); return true }
        session.login(provider: "fixture", type: "api_key")
        let requestID = sent[0]["requestId"]!
        _ = session.consume(event("model.auth", ["requestId": requestID, "provider": .string("fixture"), "stage": .string("prompt"),
            "prompt": .object(["id": .string("key"), "type": .string("secret"), "message": .string("Key")])]))
        #expect(session.answer("$ENV_KEY"))
        _ = session.consume(event("model.operation", ["requestId": requestID, "operation": .string("modelAuthReply"), "state": .string("failed"), "message": .string("请输入凭据本身，不能使用环境变量或命令")]))
        #expect(!session.isSubmittingAuthentication)
        #expect(session.authentication?.prompt?.id == "key")
        #expect(session.authenticationInput == "$ENV_KEY")
        #expect(session.answer("actual-key"))
        #expect(session.message == nil)
        #expect(sent.last?["requestId"] == requestID)
        #expect(sent.last?["promptId"] == .string("key"))
        session.updateConnection(connected: false, busy: false)
        #expect(!session.isSubmittingAuthentication)
        #expect(!session.canAnswerAuthentication("actual-key"))
        #expect(session.authenticationInput.isEmpty)
    }

    @Test func requiredAccountFieldsAndPromptTransitionsPreserveOnlyCurrentInput() {
        let session = session()
        var sent: [[String: JSONValue]] = []
        session.sendCommand = { sent.append($0); return true }
        session.login(provider: "google-vertex", type: "api_key")
        let requestID = sent[0]["requestId"]!
        _ = session.consume(event("model.auth", ["requestId": requestID, "provider": .string("google-vertex"), "stage": .string("prompt"),
            "prompt": .object(["id": .string("method"), "type": .string("select"), "message": .string("Choose"), "required": .bool(true),
                "options": .array([.object(["id": .string("api-key"), "label": .string("API key")]),
                                    .object(["id": .string("service-account"), "label": .string("Service account")])])])]))
        #expect(session.authenticationInput == "api-key")
        session.authenticationInput = "service-account"
        session.loadCatalog()
        #expect(session.authenticationInput == "service-account")
        #expect(session.answer(session.authenticationInput))
        _ = session.consume(event("model.auth", ["requestId": requestID, "provider": .string("google-vertex"), "stage": .string("prompt"),
            "prompt": .object(["id": .string("project"), "type": .string("text"), "message": .string("Enter Google Cloud project ID"), "required": .bool(true)])]))
        #expect(session.authenticationInput.isEmpty)
        #expect(!session.answer(""))
        #expect(!session.answer(" \n"))
        #expect(session.answer("my-project"))
        _ = session.consume(event("model.operation", ["requestId": requestID, "operation": .string("modelLogin"), "state": .string("failed")]))
        #expect(session.authenticationInput.isEmpty)
        #expect(session.authentication == nil)
        #expect(session.canChange)
    }

    @Test func browserAuthorizationOpensOncePerLoginAndIgnoresStaleOrNonWebLinks() {
        let session = session()
        var sent: [[String: JSONValue]] = []
        var opened: [URL] = []
        session.sendCommand = { sent.append($0); return true }
        session.openAuthenticationURL = { opened.append($0); return true }
        session.login(provider: "openai", type: "oauth")
        let requestID = sent[0]["requestId"]!
        func notice(_ id: JSONValue, _ url: String) -> AgentEvent {
            event("model.auth", ["requestId": id, "provider": .string("openai"), "stage": .string("notify"),
                "notice": .object(["type": .string("auth_url"), "url": .string(url)])])
        }
        let url = "https://example.invalid/authorize?state=fixture"
        _ = session.consume(notice(.string("stale-request"), url))
        _ = session.consume(notice(requestID, "file:///tmp/invalid"))
        #expect(opened.isEmpty)
        _ = session.consume(notice(requestID, url))
        _ = session.consume(notice(requestID, url))
        #expect(opened.map(\.absoluteString) == [url])
        #expect(session.authentication?.notices.count == 2)
        _ = session.consume(event("model.auth", ["requestId": requestID, "provider": .string("openai"), "stage": .string("notify"),
            "notice": .object(["type": .string("device_code"), "userCode": .string("ABCD-EFGH"), "verificationUri": .string("https://example.invalid/device")])]))
        #expect(opened.count == 1)
        _ = session.consume(event("model.operation", ["requestId": requestID, "operation": .string("modelLogin"), "state": .string("cancelled")]))
        session.login(provider: "openai", type: "oauth")
        _ = session.consume(notice(sent.last!["requestId"]!, url))
        #expect(opened.count == 2)
    }

    @Test func browserFailureKeepsAuthorizationLinkAndManualInputAvailable() {
        let session = session()
        var command: [String: JSONValue] = [:]
        session.sendCommand = { command = $0; return true }
        session.openAuthenticationURL = { _ in false }
        session.login(provider: "anthropic", type: "oauth")
        let requestID = command["requestId"]!
        _ = session.consume(event("model.auth", ["requestId": requestID, "provider": .string("anthropic"), "stage": .string("notify"),
            "notice": .object(["type": .string("auth_url"), "url": .string("https://example.invalid/login")])]))
        #expect(session.message == "无法打开浏览器，请点击登录链接重试")
        #expect(session.authentication?.notices.first?.loginURL != nil)
        _ = session.consume(event("model.auth", ["requestId": requestID, "provider": .string("anthropic"), "stage": .string("prompt"),
            "prompt": .object(["id": .string("code"), "type": .string("manual_code"), "message": .string("Code")])]))
        #expect(!session.canAnswerAuthentication(""))
        #expect(session.canAnswerAuthentication("fixture-code"))
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
        #expect(!session.isSubmittingAuthentication)
        #expect(session.canAnswerAuthentication("key"))
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

    @Test func initialProviderUsesSavedOrConfiguredAccountWithoutChoosingAnArbitraryCatalogEntry() {
        var catalog = PiModelCatalog()
        let unconfigured = PiProviderOption(id: "alphabetical-first", name: "First", configured: false, credentialType: nil, authMethods: [], configurationIssue: nil)
        let configured = PiProviderOption(id: "configured", name: "Configured", configured: true, credentialType: "api_key", authMethods: [], configurationIssue: nil)
        catalog.providers = [unconfigured]
        #expect(catalog.preferredProviderID == nil)
        catalog.providers.append(configured)
        #expect(catalog.preferredProviderID == "configured")
        catalog.selected = PiModelSelection(provider: "alphabetical-first", model: "saved", thinkingLevel: "off")
        #expect(catalog.preferredProviderID == "alphabetical-first")
        catalog.selected = PiModelSelection(provider: "removed", model: "missing", thinkingLevel: "off")
        #expect(catalog.preferredProviderID == "configured")
    }

    @Test func connectionTestDistinguishesUnsavedUntestedFailureAndSuccess() {
        let session = session()
        var sent: [[String: JSONValue]] = []
        session.sendCommand = { sent.append($0); return true }
        session.testConnection()
        #expect(sent.isEmpty)
        #expect(!session.canTestConnection)
        session.updateModelStatus(["configured": .bool(true), "available": .null])
        #expect(session.connectionStatus == "尚未测试连接")
        session.testConnection()
        #expect(sent.last?["op"] == .string("modelTest"))
        #expect(session.connectionStatus == "正在测试连接…")
        #expect(!session.canTestConnection)
        _ = session.consume(event("model.operation", ["requestId": sent.last!["requestId"]!, "operation": .string("modelTest"), "state": .string("failed")]))
        session.updateModelStatus(["configured": .bool(true), "available": .bool(false)])
        #expect(session.connectionStatus == "连接测试失败")
        #expect(session.canTestConnection)
        session.testConnection()
        _ = session.consume(event("model.operation", ["requestId": sent.last!["requestId"]!, "operation": .string("modelTest"), "state": .string("succeeded")]))
        session.updateModelStatus(["configured": .bool(true), "available": .bool(true)])
        #expect(session.connectionStatus == "连接测试成功")
        session.updateModelStatus(["configured": .bool(true), "available": .null])
        #expect(session.connectionStatus == "尚未测试连接")
    }
}
