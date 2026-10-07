import AppKit
import SwiftUI

@MainActor
struct ModelSettingsView: View {
    @Environment(\.locale) private var interfaceLocale
    @ObservedObject var session: ModelConfigurationSession
    @State private var query = ""
    @State private var selectedID: String?
    @State private var thinkingLevel = "off"
    private var accountProviderID: String { session.accountProviderID }
    private var isAPIKeyVisible: Bool { session.isAPIKeyVisible }
    @FocusState private var authenticationInputFocused: Bool
    private static let customProviderID = ModelConfigurationSession.customProviderID

    private var model: PiModelOption? { session.catalog.models.first { $0.id == selectedID } }
    private var account: PiProviderOption? { session.catalog.providers.first { $0.id == accountProviderID } }
    private var filteredModels: [PiModelOption] {
        guard !accountProviderID.isEmpty else { return [] }
        return session.catalog.filteredModels(query: query, provider: accountProviderID)
    }

    var body: some View {
        Group {
            accountSection
            if !session.isNewAccount, account?.configured == true, account?.apiConfiguration == nil || account?.credentialType == "oauth" { modelSelectionSection }
            if session.catalog.selected != nil { connectionSection }
            if let message = session.message ?? session.catalog.message,
               message != "模型目录已更新",
               message != session.connectionStatus,
               !(session.currentModelAvailable == false && message == session.currentModelMessage) {
                Section { Text(AppLocalization.message(message)).font(.caption).textSelection(.enabled) }
            }
            Section {
                HStack {
                    Button(AppLocalization.text("重新读取配置")) { session.reload() }.disabled(!session.canChange)
                    Button(AppLocalization.text("更新模型目录")) { session.refreshCatalog() }.disabled(!session.canChange)
                    Button(AppLocalization.text("导入 Pi 模型")) { session.importConfiguration() }.disabled(!session.canChange)
                }
            }
        }
        .onAppear { session.loadCatalog(); synchronizeSelection(); authenticationInputFocused = session.authentication?.prompt != nil }
        .onChange(of: session.catalog.selected) { _, _ in synchronizeSelection(preferSavedSelection: true) }
        .onChange(of: session.catalog.providers) { _, _ in synchronizeSelection() }
        .onChange(of: session.isNewAccount) { _, isNew in
            if !isNew { synchronizeSelection() }
        }
        .onChange(of: accountProviderID) { _, _ in
            query = ""
            session.clearAPIKey()
            selectedID = session.catalog.selected?.provider == accountProviderID ? session.catalog.selected?.id : nil
            prepareAPIConfiguration()
        }
        .onChange(of: session.apiConfigurationDraft.model) { _, value in
            selectedID = session.catalog.models.first { $0.provider == accountProviderID && $0.modelID == value }?.id
        }
        .onDisappear { session.clearAPIKey() }
        .onChange(of: query) { _, _ in
            if !filteredModels.contains(where: { $0.id == selectedID }) { selectedID = nil }
        }
        .onChange(of: selectedID) { _, _ in
            guard let model else { thinkingLevel = "off"; return }
            thinkingLevel = session.catalog.selected?.id == model.id ? session.catalog.selected!.thinkingLevel
                : model.thinkingLevels.contains("medium") ? "medium" : model.thinkingLevels.first ?? "off"
        }
        .onChange(of: session.authentication?.prompt) { _, prompt in authenticationInputFocused = prompt != nil }
    }

    private var accountSection: some View {
        Section(AppLocalization.text("账户")) {
            Picker(AppLocalization.text("提供方"), selection: $session.accountProviderID) {
                Text(AppLocalization.text("选择提供方")).tag("")
                ForEach(session.catalog.providers) { provider in Text(provider.name).tag(provider.id) }
                Divider()
                Text(AppLocalization.text("自定义 API")).tag(Self.customProviderID)
            }
            .disabled(session.isBusy)
            if account != nil, session.authentication == nil {
                if !session.providerAccounts.isEmpty {
                    Picker(AppLocalization.text("已保存账户"), selection: Binding(get: { session.accountSelection }, set: { session.selectAccount($0) })) {
                        ForEach(session.providerAccounts) { item in Text(item.name).tag(item.id) }
                        Text(AppLocalization.text("新账户")).tag("")
                    }
                    .disabled(!session.canChange)
                }
                HStack {
                    TextField(AppLocalization.text("账户名称"), text: $session.accountName)
                        .textFieldStyle(.roundedBorder)
                    Button(AppLocalization.text("添加账户")) { session.newAccount() }
                        .disabled(!session.canChange || session.isNewAccount)
                }
            }
            if let account, session.authentication == nil {
                if !session.isNewAccount && account.configured || account.apiConfiguration == nil {
                    Text(AppLocalization.text(account.configured && !session.isNewAccount ? "凭据已配置" : "请先配置账户，再选择模型"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let issue = account.configurationIssue { Text(AppLocalization.message(issue)).font(.caption).foregroundStyle(.secondary) }
                ForEach(account.authMethods.filter { $0.type != "api_key" || account.apiConfiguration == nil }) { method in
                    HStack {
                        Button(AppLocalization.text(method.type == "oauth" ? "网页登录" : "配置账户")) {
                            session.login(provider: account.id, type: method.type)
                        }
                        .help(method.name).disabled(!session.canChange)
                        Text(AppLocalization.authenticationText(method.name, locale: interfaceLocale))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if account.authMethods.isEmpty {
                    Text(AppLocalization.text("此提供方没有交互式登录，可导入自定义模型配置。"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if session.authentication == nil, accountProviderID == Self.customProviderID || account?.apiConfiguration != nil {
                apiConfigurationFields
            }
            if account?.apiConfiguration == nil, session.hasSavedAPIKey, session.authentication == nil {
                LabeledContent("API Key") {
                    HStack(spacing: 8) {
                        Text(isAPIKeyVisible ? session.revealedAPIKey : "••••••••••••")
                            .textSelection(.enabled).privacySensitive()
                        Button { session.toggleAPIKeyVisibility() } label: {
                            Image(systemName: isAPIKeyVisible ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.borderless)
                        .help(AppLocalization.text(isAPIKeyVisible ? "隐藏 API Key" : "显示 API Key"))
                        .accessibilityLabel(AppLocalization.text(isAPIKeyVisible ? "隐藏 API Key" : "显示 API Key"))
                    }
                }
                .disabled(!session.canChange)
            }
            if let authentication = session.authentication { authenticationView(authentication) }
            if let account, account.credentialType != nil, session.authentication == nil, !session.isNewAccount {
                Button(AppLocalization.text("注销账户")) { session.logout(provider: account.id) }.disabled(!session.canChange)
            }
            if session.isLoading { ProgressView().controlSize(.small) }
        }
    }

    @ViewBuilder
    private var apiConfigurationFields: some View {
        Group {
            if accountProviderID == Self.customProviderID {
                TextField(AppLocalization.text("提供方名称"), text: $session.apiConfigurationDraft.provider, prompt: Text("my-api"))
                TextField(AppLocalization.text("账户名称"), text: $session.accountName)
            }
            TextField(AppLocalization.text("接口地址 (Base URL)"), text: $session.apiConfigurationDraft.baseUrl,
                      prompt: Text("https://api.example.com/v1"))
            Picker(AppLocalization.text("API 协议"), selection: $session.apiConfigurationDraft.api) {
                Text("OpenAI Chat Completions").tag("openai-completions")
                Text("OpenAI Responses").tag("openai-responses")
                Text("Anthropic Messages").tag("anthropic-messages")
            }
            LabeledContent("API Key") {
                HStack(spacing: 8) {
                    let placeholder = session.hasSavedAPIKey ? "••••••••••••" : AppLocalization.text("输入 API Key")
                    let key = Binding(get: { session.apiConfigurationDraft.apiKey.isEmpty && isAPIKeyVisible
                        ? session.revealedAPIKey : session.apiConfigurationDraft.apiKey }, set: { session.editAPIKey($0) })
                    Group {
                        if isAPIKeyVisible {
                            TextField(placeholder, text: key)
                        } else {
                            SecureField(placeholder, text: key)
                        }
                    }
                    .labelsHidden().privacySensitive()
                    Button { session.toggleAPIKeyVisibility() } label: {
                        Image(systemName: isAPIKeyVisible ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless).frame(width: 24, height: 24)
                    .help(AppLocalization.text(isAPIKeyVisible ? "隐藏 API Key" : "显示 API Key"))
                    .accessibilityLabel(AppLocalization.text(isAPIKeyVisible ? "隐藏 API Key" : "显示 API Key"))
                }
            }
            LabeledContent(AppLocalization.text("模型 ID")) {
                HStack(spacing: 8) {
                    TextField(AppLocalization.text("选择或输入模型 ID"), text: $session.apiConfigurationDraft.model)
                        .labelsHidden()
                    if !filteredModels.isEmpty {
                        Menu {
                            ForEach(filteredModels) { model in
                                Button(model.name) { session.apiConfigurationDraft.model = model.modelID }
                            }
                        } label: { Image(systemName: "list.bullet") }
                        .menuStyle(.borderlessButton).frame(width: 24, height: 24)
                        .help(AppLocalization.text("从模型目录选择"))
                        .accessibilityLabel(AppLocalization.text("从模型目录选择"))
                    }
                }
            }
            if let model, model.provider == accountProviderID {
                Picker(AppLocalization.text("思考深度"), selection: $thinkingLevel) {
                    ForEach(model.thinkingLevels, id: \.self) { level in Text(thinkingTitle(level)).tag(level) }
                }
            }
        }
        .textFieldStyle(.roundedBorder).multilineTextAlignment(.leading)
        .disabled(!session.canChange)
        HStack {
            Button(AppLocalization.text("保存并使用")) { session.configureAPI(thinkingLevel: thinkingLevel) }
                .buttonStyle(.borderedProminent)
                .disabled(!session.canChange || !session.apiConfigurationDraft.canSave(hasSavedAPIKey: session.hasSavedAPIKey))
            if session.activeOperation == "modelConfigure" {
                ProgressView().controlSize(.small)
                Button(AppLocalization.text("取消")) { session.cancel() }
            }
        }
    }

    private var modelSelectionSection: some View {
        Section(AppLocalization.text("选择模型")) {
            TextField(AppLocalization.text("搜索模型"), text: $query)
                .textFieldStyle(.roundedBorder).multilineTextAlignment(.leading).labelsHidden()
            Text(AppLocalization.text("%d 个模型", filteredModels.count)).font(.caption).foregroundStyle(.secondary)
            ScrollView(.vertical) {
                LazyVStack(spacing: 2) {
                    ForEach(filteredModels) { model in
                        Button { selectedID = model.id } label: {
                            Text(model.name).lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(selectedID == model.id ? Color.accentColor.opacity(0.12) : .clear,
                                            in: RoundedRectangle(cornerRadius: 6))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(model.name + ", " + model.provider)
                        .accessibilityAddTraits(selectedID == model.id ? .isSelected : [])
                    }
                }
                .padding(4)
            }
            .scrollIndicators(.visible)
            .frame(height: 220)
            if let model, model.provider == accountProviderID {
                if model.name != model.modelID { Text(model.modelID).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                Picker(AppLocalization.text("思考深度"), selection: $thinkingLevel) {
                    ForEach(model.thinkingLevels, id: \.self) { level in Text(thinkingTitle(level)).tag(level) }
                }
                Button(AppLocalization.text("使用此模型")) { session.select(model, thinkingLevel: thinkingLevel) }
                    .disabled(!session.canChange || !model.configured)
            }
        }
    }

    private var connectionSection: some View {
        Section(AppLocalization.text("当前模型")) {
            if let selection = session.catalog.selected {
                LabeledContent(AppLocalization.text("模型"), value: selection.model)
                LabeledContent(AppLocalization.text("提供方"), value: selection.provider)
            }
            HStack {
                Text(AppLocalization.text(session.connectionStatus)).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if session.activeOperation == "modelTest" {
                    ProgressView().controlSize(.small)
                    Button(AppLocalization.text("取消")) { session.cancel() }
                } else {
                    Button(AppLocalization.text("测试连接")) { session.testConnection() }.disabled(!session.canTestConnection)
                }
            }
            if !session.currentModelConfigured || session.currentModelAvailable == false {
                Text(AppLocalization.message(session.currentModelMessage)).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func authenticationView(_ authentication: PiAuthentication) -> some View {
        ForEach(Array(authentication.notices.enumerated()), id: \.offset) { _, notice in
            if let message = notice.message ?? (authentication.prompt?.type == "manual_code" ? nil : notice.instructions) {
                Text(AppLocalization.authenticationText(message, locale: interfaceLocale)).font(.caption).textSelection(.enabled)
            }
            if let code = notice.userCode {
                HStack {
                    Text(code).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    Button(AppLocalization.text("复制验证码"), systemImage: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(code, forType: .string)
                    }
                    .controlSize(.small)
                }
            }
            if let url = notice.loginURL {
                Link(AppLocalization.text("打开登录页面"), destination: url)
            }
            ForEach(Array((notice.links ?? []).enumerated()), id: \.offset) { _, link in
                if let url = PiAuthNotice.webURL(link.url) { Link(link.label ?? AppLocalization.text("打开链接"), destination: url) }
            }
        }
        if let prompt = authentication.prompt, !session.isSubmittingAuthentication {
            Text(AppLocalization.authenticationText(prompt.message, locale: interfaceLocale)).font(.callout)
            if prompt.type == "select" {
                Picker(AppLocalization.text("选择"), selection: $session.authenticationInput) {
                    ForEach(prompt.options ?? []) { option in
                        Text(AppLocalization.authenticationText(option.label, locale: interfaceLocale)).tag(option.id)
                    }
                }
                if let description = prompt.options?.first(where: { $0.id == session.authenticationInput })?.description {
                    Text(description).font(.caption).foregroundStyle(.secondary)
                }
            } else if prompt.type == "secret" || prompt.type == "manual_code" {
                SecureField(prompt.placeholder ?? AppLocalization.text("输入凭据或授权码"), text: $session.authenticationInput)
                    .textFieldStyle(.roundedBorder).multilineTextAlignment(.leading).labelsHidden()
                    .focused($authenticationInputFocused)
                    .onSubmit(submitAuthentication)
            } else {
                TextField(prompt.placeholder ?? AppLocalization.text("输入"), text: $session.authenticationInput)
                    .textFieldStyle(.roundedBorder).multilineTextAlignment(.leading).labelsHidden()
                    .focused($authenticationInputFocused)
                    .onSubmit(submitAuthentication)
            }
            HStack {
                Button(AppLocalization.text("继续"), action: submitAuthentication)
                    .buttonStyle(.borderedProminent).disabled(!session.canAnswerAuthentication(session.authenticationInput))
                Button(AppLocalization.text("取消")) { session.cancel() }
            }
        } else {
            HStack {
                ProgressView().controlSize(.small)
                Text(AppLocalization.text("等待认证完成…")).font(.caption)
                Button(AppLocalization.text("取消")) { session.cancel() }
            }
        }
    }

    private func submitAuthentication() {
        session.answer(session.authenticationInput)
    }

    private func synchronizeSelection(preferSavedSelection: Bool = false) {
        session.synchronizeProvider(preferSavedSelection: preferSavedSelection)
        if let selection = session.catalog.selected, selection.provider == accountProviderID {
            selectedID = selection.id
            thinkingLevel = selection.thinkingLevel
        } else if model?.provider != accountProviderID {
            selectedID = nil
        }
        prepareAPIConfiguration()
    }

    private func prepareAPIConfiguration() {
        if accountProviderID == Self.customProviderID {
            session.prepareAPIConfiguration(provider: nil)
        } else if !accountProviderID.isEmpty {
            session.prepareAPIConfiguration(provider: accountProviderID)
        }
    }

    private func thinkingTitle(_ value: String) -> String {
        AppLocalization.reasoningEffort(value, locale: interfaceLocale)
    }
}
