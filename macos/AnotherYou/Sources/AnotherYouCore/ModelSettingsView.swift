import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct ModelSettingsView: View {
    @Environment(\.locale) private var interfaceLocale
    @ObservedObject var session: ModelConfigurationSession
    let modelsFileURL: URL
    @State private var query = ""
    @State private var providerFilter = ""
    @State private var selectedID: String?
    @State private var thinkingLevel = "off"
    @State private var accountProviderID = ""
    @State private var authenticationInput = ""

    private var model: PiModelOption? { session.catalog.models.first { $0.id == selectedID } }
    private var account: PiProviderOption? { session.catalog.providers.first { $0.id == accountProviderID } }
    private var filteredModels: [PiModelOption] { session.catalog.filteredModels(query: query, provider: providerFilter) }

    var body: some View {
        Group {
            Section(AppLocalization.text("当前模型")) {
                if let selection = session.catalog.selected {
                    LabeledContent(AppLocalization.text("模型"), value: selection.model)
                    LabeledContent(AppLocalization.text("提供方"), value: selection.provider)
                }
                Text(AppLocalization.message(session.currentModelMessage)).font(.caption).foregroundStyle(.secondary)
            }
            Section(AppLocalization.text("选择模型")) {
                TextField(AppLocalization.text("搜索模型或提供方"), text: $query)
                    .textFieldStyle(.roundedBorder)
                Picker(AppLocalization.text("提供方"), selection: $providerFilter) {
                    Text(AppLocalization.text("全部提供方")).tag("")
                    ForEach(session.catalog.providers) { provider in Text(provider.name).tag(provider.id) }
                }
                Text(AppLocalization.text("%d 个模型", filteredModels.count)).font(.caption).foregroundStyle(.secondary)
                List(filteredModels, selection: $selectedID) { model in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.name).lineLimit(1)
                        HStack(spacing: 8) {
                            Text(model.provider).lineLimit(1)
                            if model.supportsImages { Image(systemName: "photo").help(AppLocalization.text("支持图片")) }
                            Spacer(minLength: 0)
                            Text(AppLocalization.text(model.configured ? "凭据已配置" : "待配置账户"))
                        }
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    .tag(model.id)
                    .accessibilityLabel(model.name + ", " + model.provider)
                }
                .listStyle(.inset).frame(height: 220)
                if let model {
                    if model.name != model.modelID { Text(model.modelID).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                    Picker(AppLocalization.text("思考深度"), selection: $thinkingLevel) {
                        ForEach(model.thinkingLevels, id: \.self) { level in Text(thinkingTitle(level)).tag(level) }
                    }
                    Button(AppLocalization.text("使用此模型")) { session.select(model, thinkingLevel: thinkingLevel) }
                        .disabled(!session.canChange)
                }
                if session.isLoading { ProgressView().controlSize(.small) }
            }
            Section(AppLocalization.text("账户")) {
                Picker(AppLocalization.text("提供方"), selection: $accountProviderID) {
                    Text(AppLocalization.text("选择提供方")).tag("")
                    ForEach(session.catalog.providers) { provider in Text(provider.name).tag(provider.id) }
                }
                .disabled(session.isBusy)
                if let account {
                    Text(AppLocalization.text(account.configured ? "凭据已配置" : "待配置账户")).font(.caption).foregroundStyle(.secondary)
                    if let issue = account.configurationIssue { Text(AppLocalization.message(issue)).font(.caption).foregroundStyle(.secondary) }
                    HStack {
                        ForEach(account.authMethods) { method in
                            Button(AppLocalization.text(method.type == "oauth" ? "网页登录" : "配置 API 密钥")) {
                                session.login(provider: account.id, type: method.type)
                            }
                            .help(method.name).disabled(!session.canChange)
                        }
                        if account.credentialType != nil {
                            Button(AppLocalization.text("注销账户")) { session.logout(provider: account.id) }.disabled(!session.canChange)
                        }
                    }
                    if account.authMethods.isEmpty {
                        Text(AppLocalization.text("此提供方没有交互式登录，可导入自定义模型配置。"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let authentication = session.authentication { authenticationView(authentication) }
            }
            if let message = session.message ?? session.catalog.message {
                Section { Text(AppLocalization.message(message)).font(.caption).textSelection(.enabled) }
            }
            Section {
                HStack {
                    Button(AppLocalization.text("重新读取配置")) { session.reload() }.disabled(!session.canChange)
                    Button(AppLocalization.text("更新模型目录")) { session.refreshCatalog() }.disabled(!session.canChange)
                }
                DisclosureGroup(AppLocalization.text("自定义模型与导入")) {
                    Text(AppLocalization.text("导入模型和默认选择，不导入凭据。"))
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button(AppLocalization.text("导入 Pi 配置…"), action: chooseConfiguration).disabled(!session.canChange)
                        Button(AppLocalization.text("编辑自定义模型")) { NSWorkspace.shared.open(modelsFileURL) }.disabled(!session.canChange)
                    }
                }
            }
        }
        .onAppear { session.loadCatalog(); synchronizeSelection() }
        .onChange(of: session.catalog.selected) { _, _ in synchronizeSelection() }
        .onChange(of: selectedID) { _, _ in
            guard let model else { return }
            accountProviderID = model.provider
            thinkingLevel = session.catalog.selected?.id == model.id ? session.catalog.selected!.thinkingLevel
                : model.thinkingLevels.contains("medium") ? "medium" : model.thinkingLevels.first ?? "off"
        }
        .onChange(of: session.authentication?.prompt?.id) { _, _ in
            authenticationInput = session.authentication?.prompt?.options?.first?.id ?? ""
        }
        .onChange(of: session.authentication?.requestID) { _, _ in authenticationInput = "" }
    }

    @ViewBuilder
    private func authenticationView(_ authentication: PiAuthentication) -> some View {
        ForEach(Array(authentication.notices.enumerated()), id: \.offset) { _, notice in
            if let message = notice.message ?? notice.instructions { Text(message).font(.caption).textSelection(.enabled) }
            if let code = notice.userCode { Text(code).font(.system(.body, design: .monospaced)).textSelection(.enabled) }
            if let raw = notice.url ?? notice.verificationUri, let url = webURL(raw) {
                Link(AppLocalization.text("打开登录页面"), destination: url)
            }
            ForEach(Array((notice.links ?? []).enumerated()), id: \.offset) { _, link in
                if let url = webURL(link.url) { Link(link.label ?? AppLocalization.text("打开链接"), destination: url) }
            }
        }
        if let prompt = authentication.prompt {
            Text(prompt.message).font(.callout)
            if prompt.type == "select" {
                Picker(AppLocalization.text("选择"), selection: $authenticationInput) {
                    ForEach(prompt.options ?? []) { option in Text(option.label).tag(option.id) }
                }
            } else if prompt.type == "secret" || prompt.type == "manual_code" {
                SecureField(prompt.placeholder ?? AppLocalization.text("输入凭据或授权码"), text: $authenticationInput)
                    .textFieldStyle(.roundedBorder).onSubmit(submitAuthentication)
            } else {
                TextField(prompt.placeholder ?? AppLocalization.text("输入"), text: $authenticationInput)
                    .textFieldStyle(.roundedBorder).onSubmit(submitAuthentication)
            }
            HStack {
                Button(AppLocalization.text("继续"), action: submitAuthentication).disabled(authenticationInput.isEmpty)
                Button(AppLocalization.text("取消")) { session.cancel(); authenticationInput = "" }
            }
        } else {
            HStack {
                ProgressView().controlSize(.small)
                Text(AppLocalization.text("等待认证完成…")).font(.caption)
                Button(AppLocalization.text("取消")) { session.cancel(); authenticationInput = "" }
            }
        }
    }

    private func submitAuthentication() {
        if session.answer(authenticationInput) { authenticationInput = "" }
    }

    private func synchronizeSelection() {
        if let selection = session.catalog.selected {
            selectedID = selection.id
            accountProviderID = selection.provider
            thinkingLevel = selection.thinkingLevel
        }
    }

    private func chooseConfiguration() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        panel.prompt = AppLocalization.text("导入")
        panel.begin { response in
            if response == .OK, let url = panel.url { session.importConfiguration(from: url) }
        }
    }

    private func webURL(_ raw: String) -> URL? {
        guard let url = URL(string: raw), ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return url
    }

    private func thinkingTitle(_ value: String) -> String {
        AppLocalization.reasoningEffort(value, locale: interfaceLocale)
    }
}
