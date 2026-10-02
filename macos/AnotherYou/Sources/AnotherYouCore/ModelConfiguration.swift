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
    public let id: String
    public let name: String
    public let configured: Bool
    public let credentialType: String?
    public let authMethods: [AuthMethod]
    public let configurationIssue: String?
}

public struct PiModelSelection: Codable, Equatable, Sendable {
    public let provider: String
    public let model: String
    public let thinkingLevel: String
    public var id: String { provider + "/" + model }
}

public struct PiModelCatalog: Codable, Equatable, Sendable {
    public var models: [PiModelOption] = []
    public var providers: [PiProviderOption] = []
    public var selected: PiModelSelection?
    public var message: String?

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
}

public struct PiAuthentication: Equatable, Sendable {
    public let requestID: String
    public let provider: String
    public var prompt: PiAuthPrompt?
    public var notices: [PiAuthNotice] = []
}

@MainActor
public final class ModelConfigurationSession: ObservableObject {
    @Published public private(set) var catalog = PiModelCatalog()
    @Published public private(set) var isLoading = false
    @Published public private(set) var activeOperation: String?
    @Published public private(set) var authentication: PiAuthentication?
    @Published public private(set) var message: String?
    @Published public private(set) var isConnected = false
    @Published public private(set) var runtimeBusy = false
    @Published public private(set) var currentModelMessage = "请在设置中选择模型并配置账户"
    private var activeRequestID: String?
    private var catalogRequestID: String?
    var sendCommand: ([String: JSONValue]) -> Bool = { _ in false }
    var canStartOperation: () -> Bool = { false }

    public var isBusy: Bool { activeOperation != nil }
    public var canChange: Bool { isConnected && !runtimeBusy && !isBusy }

    func updateConnection(connected: Bool, busy: Bool) {
        if isConnected != connected { isConnected = connected }
        if runtimeBusy != busy { runtimeBusy = busy }
        guard !connected else { return }
        if isBusy { message = "连接已断开，账户操作已取消" }
        activeOperation = nil
        activeRequestID = nil
        authentication = nil
        catalogRequestID = nil
        isLoading = false
    }

    func updateModelStatus(_ payload: [String: JSONValue]) {
        if let value = payload["message"]?.string, currentModelMessage != value { currentModelMessage = value }
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

    public func select(_ model: PiModelOption, thinkingLevel: String) {
        begin("modelSelect", fields: ["provider": .string(model.provider), "model": .string(model.modelID), "thinkingLevel": .string(thinkingLevel)])
    }

    public func login(provider: String, type: String) {
        begin("modelLogin", fields: ["provider": .string(provider), "authType": .string(type)])
    }

    public func logout(provider: String) { begin("modelLogout", fields: ["provider": .string(provider)]) }

    public func importConfiguration(from url: URL) { begin("modelImport", fields: ["path": .string(url.path)]) }

    private func begin(_ operation: String, fields: [String: JSONValue]) {
        guard canChange, canStartOperation() else { return }
        let id = UUID().uuidString
        activeOperation = operation
        activeRequestID = id
        message = nil
        if operation == "modelLogin", let provider = fields["provider"]?.string {
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
        guard let authentication, let prompt = authentication.prompt, !value.isEmpty else { return false }
        let sent = sendCommand(["op": .string("modelAuthReply"), "requestId": .string(authentication.requestID),
                                "promptId": .string(prompt.id), "value": .string(value)])
        if !sent { message = "认证输入发送失败，请重试或取消" }
        return sent
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
        case "model.catalog":
            if let snapshot: PiModelCatalog = decode(payload) {
                if catalog != snapshot { catalog = snapshot }
                if payload["requestId"]?.string == catalogRequestID { isLoading = false; catalogRequestID = nil }
            } else {
                isLoading = false
                message = "模型目录格式无效"
            }
        case "model.operation":
            if payload["requestId"]?.string == catalogRequestID, payload["state"]?.string == "failed" {
                isLoading = false
                catalogRequestID = nil
                message = payload["message"]?.string
            }
            guard payload["requestId"]?.string == activeRequestID else { return true }
            if let value = payload["message"]?.string { message = value }
            if payload["operation"]?.string == activeOperation,
               !["started", "succeeded", "failed", "cancelled"].contains(payload["state"]?.string ?? "") {
                failAuthentication()
                return true
            }
            if ["succeeded", "failed", "cancelled"].contains(payload["state"]?.string ?? ""),
               payload["operation"]?.string == activeOperation {
                activeOperation = nil
                activeRequestID = nil
                authentication = nil
            }
        case "model.auth":
            guard var current = authentication, payload["requestId"]?.string == current.requestID else { return true }
            guard payload["provider"]?.string == current.provider else { failAuthentication(); return true }
            if payload["stage"]?.string == "prompt" {
                guard let fields = payload["prompt"]?.object, let prompt: PiAuthPrompt = decode(fields),
                      !prompt.id.isEmpty, ["text", "secret", "manual_code", "select"].contains(prompt.type),
                      prompt.type != "select" || prompt.options?.isEmpty == false else { failAuthentication(); return true }
                current.prompt = prompt
            }
            if ["promptCancelled", "promptResolved"].contains(payload["stage"]?.string ?? ""),
               payload["promptId"]?.string == current.prompt?.id { current.prompt = nil }
            if payload["stage"]?.string == "notify" {
                guard let fields = payload["notice"]?.object, let notice: PiAuthNotice = decode(fields) else { failAuthentication(); return true }
                current.notices = Array((current.notices + [notice]).suffix(8))
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
        message = "模型配置响应无效，请重新操作"
    }

    private func decode<T: Decodable>(_ value: [String: JSONValue]) -> T? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
