import Combine
import Foundation

public struct PiModelOption: Codable, Equatable, Identifiable, Sendable {
    public let modelID: String
    public let name: String
    public let provider: String
    public let input: [String]
    public let thinkingLevels: [String]
    public let contextWindow: Int
    public let maxTokens: Int
    public let configured: Bool
    public var id: String { provider + "/" + modelID }
    public var supportsImages: Bool { input.contains("image") }

    enum CodingKeys: String, CodingKey {
        case modelID = "id", name, provider, input, thinkingLevels, contextWindow, maxTokens, configured
    }
}

public struct PiProviderOption: Codable, Equatable, Identifiable, Sendable {
    public struct AuthMethod: Codable, Equatable, Identifiable, Sendable {
        public let type: String
        public let name: String
        public var id: String { type }
    }
    public struct APIConfiguration: Codable, Equatable, Sendable {
        public let baseUrl: String
        public let api: String
    }
    public let id: String
    public let name: String
    public let configured: Bool
    public let credentialType: String?
    public let authMethods: [AuthMethod]
    public let configurationIssue: String?
    public var accountId: String? = nil
    public var apiConfiguration: APIConfiguration? = nil
}

struct PiAPIConfigurationDraft: Equatable {
    static let protocols = ["openai-completions", "openai-responses", "anthropic-messages"]
    var provider = ""
    var baseUrl = ""
    var api = "openai-completions"
    var model = ""
    var apiKey = ""

    func canSave(hasSavedAPIKey: Bool) -> Bool {
        let fields = [provider, baseUrl, model].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard fields.allSatisfy({ !$0.isEmpty && $0.utf16.count <= 8192 }),
              Self.protocols.contains(api), apiKey.utf16.count <= 8192,
              hasSavedAPIKey || !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let url = URLComponents(string: fields[1]), ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              url.host?.isEmpty == false, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil,
              fields[1].rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return false }
        return true
    }
}

public struct PiModelSelection: Codable, Equatable, Sendable {
    public let provider: String
    public let model: String
    public let thinkingLevel: String
    public var id: String { provider + "/" + model }
}

public struct PiModelAccount: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let provider: String
    public let name: String
    public let hasAPIKey: Bool
    public let credentialType: String?
}

public struct PiModelCatalog: Codable, Equatable, Sendable {
    public var models: [PiModelOption] = []
    public var providers: [PiProviderOption] = []
    public var accounts: [PiModelAccount]?
    public var selected: PiModelSelection?
    public var message: String?

    public var preferredProviderID: String? {
        if let provider = selected?.provider, providers.contains(where: { $0.id == provider }) { return provider }
        return providers.first(where: \.configured)?.id
    }

    public func filteredModels(query: String, provider: String) -> [PiModelOption] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return models.filter { model in
            (provider.isEmpty || model.provider == provider) && (query.isEmpty
                || model.name.localizedCaseInsensitiveContains(query)
                || model.modelID.localizedCaseInsensitiveContains(query)
                || model.provider.localizedCaseInsensitiveContains(query))
        }
    }
}

public struct PiAuthPrompt: Codable, Equatable, Identifiable, Sendable {
    public struct Option: Codable, Equatable, Identifiable, Sendable {
        public let id: String
        public let label: String
        public let description: String?
    }
    public let id: String
    public let type: String
    public let message: String
    public let placeholder: String?
    public let options: [Option]?
    public let required: Bool?

    public func accepts(_ value: String) -> Bool {
        guard value.utf16.count <= 8192 else { return false }
        switch type {
        case "text": return required != true || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case "secret", "manual_code": return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case "select": return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && options?.contains(where: { $0.id == value }) == true
        default: return false
        }
    }
}

public struct PiAuthNotice: Codable, Equatable, Sendable {
    public struct Link: Codable, Equatable, Sendable {
        public let url: String
        public let label: String?
    }
    public let type: String
    public let message: String?
    public let url: String?
    public let instructions: String?
    public let userCode: String?
    public let verificationUri: String?
    public let links: [Link]?

    public var loginURL: URL? { Self.webURL(url ?? verificationUri ?? "") }

    public static func webURL(_ value: String) -> URL? {
        guard let url = URL(string: value), ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              url.host?.isEmpty == false else { return nil }
        return url
    }
}

public struct PiAuthentication: Equatable, Sendable {
    public let requestID: String
    public let provider: String
    public var prompt: PiAuthPrompt?
    public var notices: [PiAuthNotice] = []
}

@MainActor
public final class ModelConfigurationSession: ObservableObject {
    static let customProviderID = "__custom_api__"
    @Published var accountProviderID = "" {
        didSet {
            guard oldValue != accountProviderID else { return }
            clearAPIKey()
            isNewAccount = false
            accountName = ""
            apiDraftProviderID = nil
        }
    }
    @Published var accountName = ""
    @Published private(set) var isNewAccount = false
    @Published private(set) var isAPIKeyVisible = false
    @Published private(set) var revealedAPIKey = ""
    private var credentialRequest: (id: String, accountID: String)?
    @Published public private(set) var catalog = PiModelCatalog()
    @Published public private(set) var isLoading = false
    @Published public private(set) var activeOperation: String?
    @Published public private(set) var authentication: PiAuthentication?
    @Published public private(set) var isSubmittingAuthentication = false
    @Published public var authenticationInput = ""
    @Published var apiConfigurationDraft = PiAPIConfigurationDraft()
    @Published public private(set) var message: String?
    @Published public private(set) var isConnected = false
    @Published public private(set) var runtimeBusy = false
    @Published public private(set) var currentModelMessage = "请在设置中选择模型并配置账户"
    @Published public private(set) var currentModelConfigured = false
    @Published public private(set) var currentModelAvailable: Bool?
    private var activeRequestID: String?
    private var catalogRequestID: String?
    private var openedAuthenticationURLs: Set<URL> = []
    private var apiDraftProviderID: String?
    private var apiDraftBaseline = PiAPIConfigurationDraft()
    var sendCommand: ([String: JSONValue]) -> Bool = { _ in false }
    var canStartOperation: () -> Bool = { false }
    var openAuthenticationURL: (URL) -> Bool = { _ in false }

    public var isBusy: Bool { activeOperation != nil }
    public var canChange: Bool { isConnected && !runtimeBusy && !isBusy }
    public var canTestConnection: Bool { canChange && currentModelConfigured }
    public var connectionStatus: String {
        if activeOperation == "modelTest" { return "正在测试连接…" }
        guard currentModelConfigured else { return "待配置账户" }
        guard let currentModelAvailable else { return "尚未测试连接" }
        return currentModelAvailable ? "连接测试成功" : "连接测试失败"
    }

    func updateConnection(connected: Bool, busy: Bool) {
        if isConnected != connected { isConnected = connected }
        if runtimeBusy != busy { runtimeBusy = busy }
        guard !connected else { return }
        if isBusy { message = "连接已断开，账户操作已取消" }
        activeOperation = nil
        activeRequestID = nil
        authentication = nil
        isSubmittingAuthentication = false
        authenticationInput = ""
        clearAPIKey()
        openedAuthenticationURLs.removeAll()
        catalogRequestID = nil
        isLoading = false
    }

    func updateModelStatus(_ payload: [String: JSONValue]) {
        if let value = payload["message"]?.string, currentModelMessage != value { currentModelMessage = value }
        let configured = payload["configured"]?.bool ?? false
        if currentModelConfigured != configured { currentModelConfigured = configured }
        let available = payload["available"]?.bool
        if currentModelAvailable != available { currentModelAvailable = available }
    }

    public func loadCatalog() {
        guard isConnected, !isLoading else { return }
        let id = UUID().uuidString
        catalogRequestID = id
        isLoading = true
        if !sendCommand(["op": .string("modelCatalog"), "requestId": .string(id)]) {
            isLoading = false
            message = "无法读取模型目录"
        }
    }

    public func reload() {
        guard canChange else { return }
        if sendCommand(["op": .string("status")]) { loadCatalog() }
    }

    public func refreshCatalog() { begin("modelCatalog", fields: ["refresh": .bool(true)]) }

    public func testConnection() {
        guard canTestConnection else { return }
        begin("modelTest", fields: [:])
    }

    public func select(_ model: PiModelOption, thinkingLevel: String) {
        begin("modelSelect", fields: ["provider": .string(model.provider), "model": .string(model.modelID), "thinkingLevel": .string(thinkingLevel)].merging(accountFields) { value, _ in value })
    }

    public func login(provider: String, type: String) {
        begin("modelLogin", fields: ["provider": .string(provider), "authType": .string(type)].merging(accountFields) { value, _ in value })
    }

    func synchronizeProvider(preferSavedSelection: Bool = false) {
        if let authentication {
            accountProviderID = authentication.provider
        } else if preferSavedSelection || (accountProviderID != Self.customProviderID && !catalog.providers.contains(where: { $0.id == accountProviderID })) {
            accountProviderID = catalog.preferredProviderID ?? ""
        }
    }

    func prepareAPIConfiguration(provider: String?) {
        let id = (provider ?? "") + "/" + (isNewAccount ? "new" : activeAccountID ?? "")
        if apiDraftProviderID == id, apiConfigurationDraft != apiDraftBaseline { return }
        if apiDraftProviderID != id {
            clearAPIKey()
            if !isNewAccount { accountName = currentAccount?.name ?? "" }
        }
        apiDraftProviderID = id
        if let provider {
            guard let configuration = catalog.providers.first(where: { $0.id == provider })?.apiConfiguration else { return }
            apiConfigurationDraft = PiAPIConfigurationDraft(provider: provider, baseUrl: configuration.baseUrl,
                api: configuration.api, model: catalog.selected?.provider == provider ? catalog.selected!.model : "")
        } else {
            let ids = Set(catalog.providers.map(\.id))
            var name = "custom"
            var suffix = 2
            while ids.contains(name) { name = "custom-\(suffix)"; suffix += 1 }
            apiConfigurationDraft = PiAPIConfigurationDraft(provider: name)
        }
        apiDraftProviderID = id
        apiDraftBaseline = apiConfigurationDraft
    }

    var hasSavedAPIKey: Bool {
        guard !isNewAccount else { return false }
        if let currentAccount { return currentAccount.hasAPIKey }
        return catalog.providers.contains { $0.id == apiConfigurationDraft.provider && $0.credentialType == "api_key" && $0.configured }
    }

    func configureAPI(thinkingLevel: String) {
        let draft = apiConfigurationDraft
        guard draft.canSave(hasSavedAPIKey: hasSavedAPIKey) else { return }
        var fields: [String: JSONValue] = ["provider": .string(draft.provider.trimmingCharacters(in: .whitespacesAndNewlines)),
            "baseUrl": .string(draft.baseUrl.trimmingCharacters(in: .whitespacesAndNewlines)),
            "api": .string(draft.api), "model": .string(draft.model.trimmingCharacters(in: .whitespacesAndNewlines)),
            "thinkingLevel": .string(thinkingLevel)]
        let key = draft.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty { fields["apiKey"] = .string(key) }
        begin("modelConfigure", fields: fields.merging(accountFields) { value, _ in value })
    }

    var providerAccounts: [PiModelAccount] { (catalog.accounts ?? []).filter { $0.provider == accountProviderID } }
    var activeAccountID: String? { catalog.providers.first { $0.id == accountProviderID }?.accountId }
    var currentAccount: PiModelAccount? { providerAccounts.first { $0.id == activeAccountID } }
    var accountSelection: String { isNewAccount ? "" : activeAccountID ?? "" }
    private var accountFields: [String: JSONValue] {
        var fields: [String: JSONValue] = [:]
        if isNewAccount { fields["newAccount"] = .bool(true) }
        else if let id = activeAccountID { fields["accountId"] = .string(id) }
        let name = accountName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { fields["accountName"] = .string(name) }
        return fields
    }

    func newAccount() {
        guard canChange else { return }
        clearAPIKey()
        isNewAccount = true
        accountName = ""
        apiDraftProviderID = nil
        prepareAPIConfiguration(provider: accountProviderID == Self.customProviderID ? nil : accountProviderID)
    }

    func selectAccount(_ id: String) {
        guard canChange else { return }
        if id.isEmpty { newAccount(); return }
        clearAPIKey()
        if id == activeAccountID {
            isNewAccount = false
            apiDraftProviderID = nil
            prepareAPIConfiguration(provider: accountProviderID)
        } else { begin("modelAccountSelect", fields: ["accountId": .string(id)]) }
    }

    private func hideAPIKey() {
        credentialRequest = nil
        revealedAPIKey = ""
        isAPIKeyVisible = false
    }

    func clearAPIKey() {
        hideAPIKey()
        apiConfigurationDraft.apiKey = ""
    }

    func editAPIKey(_ value: String) {
        credentialRequest = nil
        revealedAPIKey = ""
        apiConfigurationDraft.apiKey = value
    }

    func toggleAPIKeyVisibility() {
        if isAPIKeyVisible {
            isAPIKeyVisible = false
            revealedAPIKey = ""
            credentialRequest = nil
            return
        }
        isAPIKeyVisible = true
        guard apiConfigurationDraft.apiKey.isEmpty, hasSavedAPIKey, let accountID = activeAccountID, isConnected else { return }
        let id = UUID().uuidString
        credentialRequest = (id, accountID)
        if !sendCommand(["op": .string("modelCredentialRead"), "requestId": .string(id), "accountId": .string(accountID)]) {
            credentialRequest = nil
            isAPIKeyVisible = false
            message = "无法读取 API Key"
        }
    }

    public func logout(provider: String) { begin("modelLogout", fields: ["provider": .string(provider)]) }

    public func importConfiguration() { begin("modelImport", fields: [:]) }

    private func begin(_ operation: String, fields: [String: JSONValue]) {
        guard canChange, canStartOperation() else { return }
        hideAPIKey()
        let id = UUID().uuidString
        activeOperation = operation
        activeRequestID = id
        message = nil
        if operation == "modelLogin", let provider = fields["provider"]?.string {
            authenticationInput = ""
            openedAuthenticationURLs.removeAll()
            authentication = PiAuthentication(requestID: id, provider: provider)
        }
        if !sendCommand(fields.merging(["op": .string(operation), "requestId": .string(id)]) { _, value in value }) {
            activeOperation = nil
            activeRequestID = nil
            authentication = nil
            message = "模型配置命令发送失败"
        }
    }

    @discardableResult
    public func answer(_ value: String) -> Bool {
        guard canAnswerAuthentication(value), let authentication, let prompt = authentication.prompt else { return false }
        isSubmittingAuthentication = true
        authenticationInput = value
        message = nil
        let sent = sendCommand(["op": .string("modelAuthReply"), "requestId": .string(authentication.requestID),
                                "promptId": .string(prompt.id), "value": .string(value)])
        if !sent {
            isSubmittingAuthentication = false
            message = "认证输入发送失败，请重试或取消"
        }
        return sent
    }

    public func canAnswerAuthentication(_ value: String) -> Bool {
        isConnected && !isSubmittingAuthentication && authentication?.prompt?.accepts(value) == true
    }

    public func cancel() {
        guard let activeRequestID else { return }
        if !sendCommand(["op": .string("modelAuthCancel"), "requestId": .string(activeRequestID)]) {
            message = "取消命令发送失败，请重试"
        }
    }

    func consume(_ event: AgentEvent) -> Bool {
        let payload = event.payload
        if event.kind == "agent.error", let id = payload["requestId"]?.string {
            if id == credentialRequest?.id { hideAPIKey(); message = "无法读取 API Key"; return true }
            if id == activeRequestID { failAuthentication(); return true }
            if id == catalogRequestID {
                isLoading = false
                catalogRequestID = nil
                message = "无法读取模型目录"
                return true
            }
        }
        guard event.kind.hasPrefix("model.") else { return false }
        switch event.kind {
        case "model.credential":
            guard let request = credentialRequest, isConnected, isAPIKeyVisible, !isNewAccount,
                  payload["requestId"]?.string == request.id, payload["accountId"]?.string == request.accountID,
                  activeAccountID == request.accountID, apiConfigurationDraft.apiKey.isEmpty else { return true }
            credentialRequest = nil
            revealedAPIKey = payload["apiKey"]?.string ?? ""
        case "model.catalog":
            if let snapshot: PiModelCatalog = decode(payload) {
                let previousAccount = activeAccountID
                if catalog != snapshot { catalog = snapshot }
                if previousAccount != activeAccountID {
                    clearAPIKey()
                    isNewAccount = false
                    apiDraftProviderID = nil
                }
                if payload["requestId"]?.string == catalogRequestID { isLoading = false; catalogRequestID = nil }
            } else {
                isLoading = false
                message = "模型目录格式无效"
            }
        case "model.operation":
            if payload["requestId"]?.string == credentialRequest?.id, payload["state"]?.string == "failed" {
                credentialRequest = nil
                isAPIKeyVisible = false
                message = payload["message"]?.string
                return true
            }
            if payload["requestId"]?.string == catalogRequestID, payload["state"]?.string == "failed" {
                isLoading = false
                catalogRequestID = nil
                message = payload["message"]?.string
            }
            guard payload["requestId"]?.string == activeRequestID else { return true }
            if let value = payload["message"]?.string { message = value }
            if payload["operation"]?.string == "modelAuthReply", payload["state"]?.string == "failed" {
                isSubmittingAuthentication = false
            }
            if payload["operation"]?.string == activeOperation,
               !["started", "succeeded", "failed", "cancelled"].contains(payload["state"]?.string ?? "") {
                failAuthentication()
                return true
            }
            if ["succeeded", "failed", "cancelled"].contains(payload["state"]?.string ?? ""),
               payload["operation"]?.string == activeOperation {
                if activeOperation == "modelConfigure", payload["state"]?.string == "succeeded" {
                    clearAPIKey()
                    isNewAccount = false
                    apiDraftBaseline = apiConfigurationDraft
                }
                if payload["state"]?.string == "cancelled" { message = nil }
                activeOperation = nil
                activeRequestID = nil
                authentication = nil
                isSubmittingAuthentication = false
                authenticationInput = ""
                openedAuthenticationURLs.removeAll()
            }
        case "model.auth":
            guard var current = authentication, payload["requestId"]?.string == current.requestID else { return true }
            guard payload["provider"]?.string == current.provider else { failAuthentication(); return true }
            if payload["stage"]?.string == "prompt" {
                guard let fields = payload["prompt"]?.object, let prompt: PiAuthPrompt = decode(fields),
                      !prompt.id.isEmpty, ["text", "secret", "manual_code", "select"].contains(prompt.type),
                      prompt.type != "select" || prompt.options?.isEmpty == false else { failAuthentication(); return true }
                current.prompt = prompt
                isSubmittingAuthentication = false
                authenticationInput = prompt.options?.first?.id ?? ""
            }
            if ["promptCancelled", "promptResolved"].contains(payload["stage"]?.string ?? ""),
               payload["promptId"]?.string == current.prompt?.id {
                current.prompt = nil
                isSubmittingAuthentication = false
                authenticationInput = ""
            }
            if payload["stage"]?.string == "notify" {
                guard let fields = payload["notice"]?.object, let notice: PiAuthNotice = decode(fields) else { failAuthentication(); return true }
                if notice.type == "progress" { current.notices.removeAll { $0.type == "progress" } }
                if !current.notices.contains(notice) { current.notices = Array((current.notices + [notice]).suffix(8)) }
                if notice.type == "auth_url", let url = notice.loginURL, openedAuthenticationURLs.insert(url).inserted,
                   !openAuthenticationURL(url) { message = "无法打开浏览器，请点击登录链接重试" }
            }
            guard ["prompt", "promptCancelled", "promptResolved", "notify"].contains(payload["stage"]?.string ?? "") else { failAuthentication(); return true }
            authentication = current
        default: break
        }
        return true
    }

    private func failAuthentication() {
        cancel()
        activeOperation = nil
        activeRequestID = nil
        authentication = nil
        isSubmittingAuthentication = false
        authenticationInput = ""
        openedAuthenticationURLs.removeAll()
        message = "模型配置响应无效，请重新操作"
    }

    private func decode<T: Decodable>(_ value: [String: JSONValue]) -> T? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
