import Combine
import Foundation
import SwiftUI

struct LocalModelDraft: Equatable {
    var provider = "ollama"
    var baseUrl = "http://127.0.0.1:11434"
    var model = ""
    var apiKey = ""

    var validAddress: Bool {
        guard let url = URLComponents(string: baseUrl.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host?.isEmpty == false,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { return false }
        return true
    }

    var configuration: [String: JSONValue] {
        var fields: [String: JSONValue] = ["provider": .string(provider), "baseUrl": .string(baseUrl.trimmingCharacters(in: .whitespacesAndNewlines)),
                                         "model": .string(model.trimmingCharacters(in: .whitespacesAndNewlines))]
        if !apiKey.isEmpty { fields["apiKey"] = .string(apiKey) }
        return fields
    }
}

@MainActor
public final class LocalModelSettingsSession: ObservableObject {
    @Published var draft = LocalModelDraft()
    @Published private(set) var models: [String] = []
    @Published private(set) var recommendation: [String: JSONValue] = [:]
    @Published private(set) var message: String?
    @Published private(set) var configured = false
    @Published private(set) var available: Bool?
    @Published private(set) var statusMessage = "请配置本地模型后开启工作分析"
    @Published private(set) var isConnected = false
    @Published private(set) var activeOperation: String?
    @Published private(set) var hasAPIKey = false
    @Published private(set) var workLookbackHours = 24
    private var requestID: String?
    private var baseline = LocalModelDraft()
    private var savingDraft: LocalModelDraft?
    private var receivedConfiguration = false
    var sendCommand: ([String: JSONValue]) -> Bool = { _ in false }
    var canStartOperation: () -> Bool = { false }

    public var isBusy: Bool { activeOperation != nil }
    var canChange: Bool { isConnected && !isBusy && canStartOperation() }
    var hasUnsavedChanges: Bool { draft != baseline }

    func updateConnection(_ connected: Bool) {
        guard isConnected != connected else { return }
        isConnected = connected
        if !connected {
            if isBusy { message = "本地模型连接已断开" }
            requestID = nil
            activeOperation = nil
            savingDraft = nil
            draft.apiKey = ""
        }
    }

    func update(_ payload: [String: JSONValue]) {
        if case .number(let hours) = payload["workLookbackHours"], [24.0, 168.0, 720.0].contains(hours) { workLookbackHours = Int(hours) }
        configured = payload["configured"]?.bool ?? false
        available = payload["available"]?.bool
        hasAPIKey = payload["hasAPIKey"]?.bool ?? false
        statusMessage = payload["message"]?.string ?? "请配置本地模型后开启工作分析"
        recommendation = payload["recommendation"]?.object ?? [:]
        if let fields = payload["configuration"]?.object {
            let saved = LocalModelDraft(provider: fields["provider"]?.string ?? "ollama",
                baseUrl: fields["baseUrl"]?.string ?? "http://127.0.0.1:11434", model: fields["model"]?.string ?? "")
            if !receivedConfiguration || draft == baseline { draft = saved }
            baseline = saved
            receivedConfiguration = true
        }
    }

    func selectProvider(_ provider: String) {
        guard provider != draft.provider else { return }
        draft.provider = provider
        draft.baseUrl = provider == "ollama" ? "http://127.0.0.1:11434" : "http://127.0.0.1:1234/v1"
        draft.model = ""
        draft.apiKey = ""
        models = []
        message = nil
    }

    func loadModels() {
        guard draft.validAddress else { return }
        var fields = draft.configuration
        // 同一服务目录请求可以复用已保存的令牌，令牌本身不回传到界面。
        if draft.apiKey.isEmpty, draft.provider == baseline.provider, draft.baseUrl == baseline.baseUrl { fields["useSavedAPIKey"] = .bool(true) }
        begin("localModelModels", fields: ["localModel": .object(fields)])
    }

    func save() {
        guard draft.validAddress else { return }
        savingDraft = draft
        begin("localModelConfigure", fields: ["localModel": .object(draft.configuration)])
    }

    func testConnection() {
        guard configured, !hasUnsavedChanges else { return }
        begin("localModelTest", fields: [:])
    }

    func checkNow() { begin("proactiveCheck", fields: [:]) }

    func selectWorkLookback(_ hours: Int) {
        guard [24, 168, 720].contains(hours), hours != workLookbackHours else { return }
        begin("proactiveConfigure", fields: ["workLookbackHours": .number(Double(hours))])
    }

    func cancel() {
        guard let requestID else { return }
        _ = sendCommand(["op": .string("localModelCancel"), "requestId": .string(requestID)])
    }

    private func begin(_ operation: String, fields: [String: JSONValue]) {
        guard canChange else { savingDraft = nil; return }
        let id = UUID().uuidString
        requestID = id
        activeOperation = operation
        message = nil
        if !sendCommand(fields.merging(["op": .string(operation), "requestId": .string(id)]) { _, new in new }) {
            requestID = nil; activeOperation = nil; savingDraft = nil
            message = "本地模型命令发送失败"
        }
    }

    func consume(_ event: AgentEvent) -> Bool {
        guard event.kind == "localModel.operation" else { return false }
        let fields = event.payload
        guard fields["requestId"]?.string == requestID, fields["operation"]?.string == activeOperation else { return true }
        let state = fields["state"]?.string
        if let text = fields["message"]?.string { message = text }
        if let values = fields["models"]?.array { models = values.compactMap(\.string) }
        if ["succeeded", "failed", "cancelled"].contains(state ?? "") {
            if state == "succeeded", activeOperation == "proactiveConfigure",
               case .number(let hours) = fields["workLookbackHours"], [24.0, 168.0, 720.0].contains(hours) { workLookbackHours = Int(hours) }
            if state == "succeeded", activeOperation == "localModelConfigure", var saved = savingDraft {
                let unchanged = draft == saved
                saved.apiKey = ""
                baseline = saved
                draft.apiKey = ""
                if unchanged { draft = saved }
            }
            requestID = nil; activeOperation = nil; savingDraft = nil
        }
        return true
    }
}

struct LocalModelSettingsView: View {
    @ObservedObject var session: LocalModelSettingsSession
    let paused: Bool

    var body: some View {
        Section(AppLocalization.text("本地工作助手")) {
            if let name = session.recommendation["name"]?.string,
               case .number(let memory) = session.recommendation["memoryGB"] {
                LabeledContent(AppLocalization.text("这台 Mac"), value: "\(Int(memory)) GB · \(session.recommendation["cpu"]?.string ?? "")")
                LabeledContent(AppLocalization.text("推荐模型"), value: name)
                Text(AppLocalization.text("建议使用 4 位量化模型；繁忙时可选更小模型。请先在本地服务中下载并加载。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Picker(AppLocalization.text("本地服务"), selection: Binding(get: { session.draft.provider }, set: session.selectProvider)) {
                Text("Ollama").tag("ollama")
                Text("LM Studio").tag("lmstudio")
            }
            .disabled(!session.canChange)
            TextField(AppLocalization.text("服务地址"), text: $session.draft.baseUrl)
                .textFieldStyle(.roundedBorder).multilineTextAlignment(.leading).disabled(!session.canChange)
            HStack {
                TextField(AppLocalization.text("模型 ID"), text: $session.draft.model)
                    .textFieldStyle(.roundedBorder).multilineTextAlignment(.leading)
                if !session.models.isEmpty {
                    Menu(AppLocalization.text("选择模型")) {
                        ForEach(session.models, id: \.self) { model in Button(model) { session.draft.model = model } }
                    }.fixedSize()
                }
                Button(AppLocalization.text("读取模型")) { session.loadModels() }.disabled(!session.draft.validAddress)
            }.disabled(!session.canChange)
            SecureField(AppLocalization.text(session.hasAPIKey ? "留空保留已保存的密钥" : "API Key（可选）"), text: $session.draft.apiKey)
                .textFieldStyle(.roundedBorder).multilineTextAlignment(.leading).privacySensitive().disabled(!session.canChange)
            HStack {
                Button(AppLocalization.text("保存配置")) { session.save() }
                    .buttonStyle(.borderedProminent).disabled(!session.canChange || !session.draft.validAddress)
                Button(AppLocalization.text("测试连接")) { session.testConnection() }
                    .disabled(!session.canChange || !session.configured || session.hasUnsavedChanges)
                Button(AppLocalization.text("立即检查")) { session.checkNow() }
                    .disabled(!session.canChange || !session.configured || session.hasUnsavedChanges || paused)
                if session.isBusy {
                    ProgressView().controlSize(.small)
                    Button(AppLocalization.text("取消")) { session.cancel() }
                }
            }
            Text(AppLocalization.message(session.message ?? session.statusMessage)).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        }
    }
}
