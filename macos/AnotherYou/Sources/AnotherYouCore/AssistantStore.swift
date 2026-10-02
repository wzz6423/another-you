import AppKit
import Combine
import CoreGraphics
import Foundation
import UserNotifications

enum InputDraftLocation: Hashable {
    case conversation, quickChat
}

@MainActor
final class InputDraft: ObservableObject {
    @Published fileprivate(set) var text = ""
}

@MainActor
public final class AssistantStore: ObservableObject {
    @Published public private(set) var cards: [ProactiveCard] = []
    @Published public private(set) var usageRecords: [UsageRecord] = []
    @Published public private(set) var history: [AgentEvent] = []
    private var historyPrunedAt = Date.distantPast
    @Published public private(set) var conversation: [ConversationMessage] = []
    @Published public private(set) var sessions: [ConversationSession] = []
    @Published public private(set) var selectedConversationID: String?
    @Published public private(set) var pendingConversationActions: Set<String> = []
    @Published public private(set) var conversationActionError: String?
    @Published public private(set) var isLoadingConversation = false
    private var conversationReadID: String?
    private var pendingConversationFork: (requestID: String, sourceID: String)?
    private struct ConversationDraft {
        let text: String
        let attachments: [ScreenAttachment]
    }
    private var conversationDrafts: [String: ConversationDraft] = [:]
    private var sentAttachments: [String: [ScreenAttachment]] = [:]
    @Published public private(set) var lastUpdated: Date?
    @Published public private(set) var statusMessage = "Agent 未启动"
    @Published public private(set) var connection: ConnectionState = .stopped
    @Published public private(set) var paused = false
    @Published public private(set) var isChangingPause = false
    @Published public private(set) var isRestarting = false
    @Published public private(set) var modelConfigured = false
    @Published public private(set) var modelMessage = "请在设置中选择模型并配置账户"
    @Published public private(set) var modelName = ""
    @Published public private(set) var modelProvider = ""
    @Published public private(set) var reasoningEffort = ""
    @Published public private(set) var pendingActions: Set<String> = []
    @Published public private(set) var notificationsEnabled: Bool
    @Published public private(set) var notificationMessage: String?
    @Published public private(set) var appearance: AppAppearance
    private var inputDrafts: [InputDraftLocation: InputDraft] = [:]
    public let updates: UpdateController
    public let desktop: DesktopSession
    public let proactiveContext: ProactiveContextSession
    public let modelSettings = ModelConfigurationSession()
    public var modelsFileURL: URL { repository.piDirectory.appendingPathComponent("models.json") }

    private let agent: any AgentClient
    private let repository: AgentSettingsRepository
    private let defaults: UserDefaults
    private var idleTask: Task<Void, Never>?
    private var hasSentLaunchSignal = false
    private var isShuttingDown = false
    private var hasActiveBackgroundAnalysis = false
    private var desktopObservation: AnyCancellable?

    public init(
        client: any AgentClient = ProcessAgentClient(),
        repository: AgentSettingsRepository = AgentSettingsRepository(),
        defaults: UserDefaults = .standard,
        updater: UpdateController? = nil,
        desktop: DesktopSession = DesktopSession(),
        contextCollector: any ContextCollecting = SystemContextCollector()
    ) {
        self.agent = client
        self.repository = repository
        self.defaults = defaults
        self.desktop = desktop
        proactiveContext = ProactiveContextSession(collector: contextCollector)
        appearance = AppAppearance(rawValue: defaults.string(forKey: "appearance") ?? "") ?? .system
        updates = updater ?? UpdateController(defaults: defaults)
        notificationsEnabled = defaults.bool(forKey: "notificationsEnabled")
        agent.onMessage = { [weak self] message in self?.receive(message) }
        updates.isIdle = { [weak self] in self?.canInstallUpdate == true }
        desktop.canStartOperation = { [weak self] in
            guard let self else { return false }
            return !self.updates.isInstalling && !self.isShuttingDown
        }
        desktopObservation = desktop.objectWillChange.sink { [weak self] in
            self?.scheduleUpdateInstallation()
        }
        modelSettings.sendCommand = { [weak self] command in self?.send(command) == true }
        modelSettings.canStartOperation = { [weak self] in
            guard let self else { return false }
            return self.isConnected && !self.hasPendingPrompt && !self.hasActiveBackgroundAnalysis
                && !self.cards.contains { $0.state == .running } && self.pendingActions.isEmpty
                && !self.updates.isInstalling && !self.isShuttingDown
        }
        appearance.apply()
    }

    public func setAppearance(_ appearance: AppAppearance) {
        self.appearance = appearance
        defaults.set(appearance.rawValue, forKey: "appearance")
        appearance.apply()
    }

    public var isConnected: Bool { connection == .connected }
    public var completedCount: Int { cards.filter { $0.state == .completed }.count }
    public var pendingCount: Int { cards.filter { $0.state == .pending }.count }
    public var hasPendingPrompt: Bool { conversation.contains(where: \.isPending) || sessions.contains { $0.state == "running" } }
    public var canInstallUpdate: Bool {
        !hasPendingPrompt && !cards.contains(where: { $0.state == .running }) && pendingActions.isEmpty
            && !desktop.isCapturing && desktop.activity == nil && desktop.attachments.isEmpty
            && !isChangingPause && !isRestarting && !isShuttingDown && connection != .starting
            && inputDrafts.values.allSatisfy { $0.text.isEmpty }
            && conversationDrafts.values.allSatisfy { $0.text.isEmpty && $0.attachments.isEmpty }
            && !hasActiveBackgroundAnalysis
            && !modelSettings.isBusy && pendingConversationActions.isEmpty && !isLoadingConversation
    }

    func draft(for location: InputDraftLocation) -> InputDraft {
        if let draft = inputDrafts[location] { return draft }
        let draft = InputDraft()
        inputDrafts[location] = draft
        return draft
    }

    func inputDraft(for location: InputDraftLocation) -> String { inputDrafts[location]?.text ?? "" }

    func setInputDraft(_ text: String, for location: InputDraftLocation) {
        guard !updates.isInstalling else { return }
        let draft = draft(for: location)
        guard draft.text != text else { return }
        draft.text = text
        if text.isEmpty { scheduleUpdateInstallation() }
    }

    private func scheduleUpdateInstallation() {
        DispatchQueue.main.async { [weak self] in self?.updates.installWhenIdle() }
    }
    public var notificationSupported: Bool {
        Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil
    }
    public var activeCards: [ProactiveCard] { cards.filter { $0.state != .ignored && !$0.archived } }
    public var nextDueDate: Date? { cards.filter { $0.state == .snoozed }.compactMap(\.snoozedUntil).min() }
    public var activityHistory: [AgentEvent] {
        history.filter { $0.activityCategory != nil }
    }

    public func connect() {
        updates.start()
        guard !isConnected, connection != .starting, !isRestarting, !updates.isInstalling else { return }
        hasSentLaunchSignal = false
        do {
            try repository.ensureConfig()
            try agent.start(configURL: repository.configURL)
        } catch { receive(.connection(.failed(error.localizedDescription))) }
    }

    public func refresh() {
        if isConnected { send(["op": .string("status")]) }
        else { connect() }
    }

    public func shutdown() async {
        isShuttingDown = true
        proactiveContext.cancel()
        desktop.cancel()
        idleTask?.cancel()
        await agent.stop()
    }

    public func togglePause() {
        guard isConnected, !isChangingPause else { return }
        isChangingPause = true
        if !send(["op": .string(paused ? "resume" : "pause")]) { isChangingPause = false }
    }

    public func apply(_ action: CardAction, to card: ProactiveCard) {
        guard isConnected, !updates.isInstalling, !pendingActions.contains(card.id),
              card.state == .pending || card.state == .failed || card.state == .snoozed else { return }
        if action == .execute && !modelConfigured {
            statusMessage = "请先在设置中选择模型并配置账户。"
            return
        }
        if action == .execute && modelSettings.isBusy { return }
        pendingActions.insert(card.id)
        if !send(["op": .string("decide"), "suggestionId": .string(card.id), "decision": .string(action.rawValue)]) {
            pendingActions.remove(card.id)
        }
    }

    @discardableResult
    public func ask(_ prompt: String) -> Bool {
        var prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if prompt.isEmpty && !desktop.attachments.isEmpty { prompt = "请分析截图及应用上下文。" }
        guard !prompt.isEmpty, isConnected, modelConfigured, !hasPendingPrompt, !updates.isInstalling, !modelSettings.isBusy, !selectedConversationArchived, !isLoadingConversation,
              pendingConversationActions.isEmpty, selectedConversationID == nil || conversationActionError == nil else { return false }
        conversationActionError = nil
        let id = UUID().uuidString
        let sessionID = selectedConversationID ?? UUID().uuidString
        if selectedConversationID == nil {
            conversationDrafts.removeValue(forKey: "")
        }
        selectedConversationID = sessionID
        sentAttachments[id] = desktop.attachments
        conversation.append(ConversationMessage(id: id, prompt: prompt, attachments: desktop.attachments))
        let captures = desktop.attachments.map(\.payload)
        if !send(["op": .string("prompt"), "requestId": .string(id), "conversationId": .string(sessionID), "prompt": .string(prompt),
                  "attachments": .array(captures), "allowForeground": .bool(desktop.allowForeground)]) {
            conversation[conversation.count - 1].error = statusMessage
            return false
        }
        desktop.clearAttachments()
        return true
    }

    public func newConversation() {
        guard !hasPendingPrompt, pendingConversationFork == nil else { return }
        switchConversationDraft(to: nil)
        selectedConversationID = nil
        conversation = []
        conversationActionError = nil
        finishConversationRead()
    }

    public func selectConversation(_ id: String) {
        guard !hasPendingPrompt, pendingConversationFork == nil, let session = sessions.first(where: { $0.id == id }) else { return }
        switchConversationDraft(to: id)
        selectedConversationID = id
        conversationActionError = nil
        conversation = messagesWithAttachments(session.messages)
        let readID = UUID().uuidString
        conversationReadID = readID
        isLoadingConversation = true
        if !send(["op": .string("conversationRead"), "conversationId": .string(id), "readId": .string(readID)]) {
            conversationActionError = statusMessage
            finishConversationRead()
        }
    }

    private func switchConversationDraft(to id: String?) {
        guard selectedConversationID != id else { return }
        conversationDrafts[selectedConversationID ?? ""] = ConversationDraft(text: inputDraft(for: .conversation), attachments: desktop.attachments)
        restoreConversationDraft(id)
    }

    private func restoreConversationDraft(_ id: String?) {
        let saved = conversationDrafts.removeValue(forKey: id ?? "")
        setInputDraft(saved?.text ?? "", for: .conversation)
        desktop.replaceAttachments(saved?.attachments ?? [])
    }

    public var canForkConversation: Bool {
        isConnected && !updates.isInstalling && !hasPendingPrompt && !isLoadingConversation
            && pendingConversationActions.isEmpty && conversationActionError == nil
            && selectedConversationID != nil && !conversation.isEmpty
    }

    public func forkConversation(through messageID: String? = nil) {
        guard canForkConversation, let id = selectedConversationID,
              messageID == nil || conversation.contains(where: { $0.id == messageID }) else { return }
        let requestID = UUID().uuidString
        pendingConversationFork = (requestID, id)
        pendingConversationActions.insert(id)
        var command: [String: JSONValue] = ["op": .string("conversationFork"), "conversationId": .string(id), "requestId": .string(requestID)]
        if let messageID { command["messageId"] = .string(messageID) }
        if !send(command) {
            pendingConversationFork = nil
            pendingConversationActions.remove(id)
            conversationActionError = statusMessage
        }
    }

    private func finishConversationRead() {
        conversationReadID = nil
        isLoadingConversation = false
    }

    private func consumeConversationMessages(_ payload: [String: JSONValue]) {
        guard let readID = payload["readId"]?.string, readID == conversationReadID,
              payload["conversationId"]?.string == selectedConversationID else { return }
        defer { finishConversationRead() }
        guard let value = payload["conversation"]?.object,
              let session = ConversationSession(payload: value), session.id == selectedConversationID else {
            conversationActionError = AppLocalization.text("无法读取会话内容，请重试。")
            return
        }
        conversation = messagesWithAttachments(session.messages)
        if let index = sessions.firstIndex(where: { $0.id == session.id }) { sessions[index] = session }
    }

    public func manageConversation(_ id: String, action: String) {
        guard isConnected, !updates.isInstalling, !pendingConversationActions.contains(id), pendingConversationFork == nil,
              !sessions.contains(where: { $0.id == id && $0.state == "running" }),
              !cards.contains(where: { $0.id == id && $0.state == .running }) else { return }
        conversationActionError = nil
        pendingConversationActions.insert(id)
        if !send(["op": .string("conversationAction"), "conversationId": .string(id), "action": .string(action)]) {
            pendingConversationActions.remove(id)
            conversationActionError = statusMessage
        }
    }

    public var selectedConversationArchived: Bool {
        sessions.first { $0.id == selectedConversationID }?.archived == true
    }

    private func messagesWithAttachments(_ messages: [ConversationMessage]) -> [ConversationMessage] {
        messages.map { message in
            var value = message
            value.attachments = sentAttachments[message.id] ?? []
            return value
        }
    }

    private func consumeSessions(_ payload: [String: JSONValue]) {
        guard let values = payload["conversations"]?.array else { return }
        let previous = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0.messages) })
        let decoded = values.compactMap { value -> ConversationSession? in
            guard let payload = value.object, var session = ConversationSession(payload: payload) else { return nil }
            if payload["messages"] == nil {
                session.messages = session.id == selectedConversationID ? conversation : previous[session.id] ?? []
            }
            return session
        }.sorted { $0.updatedAt > $1.updatedAt }
        setIfChanged(\.sessions, to: decoded)
        if let id = selectedConversationID {
            if let session = sessions.first(where: { $0.id == id }) { setIfChanged(\.conversation, to: messagesWithAttachments(session.messages)) }
            else if !conversation.contains(where: \.isPending) {
                conversationDrafts.removeValue(forKey: id)
                selectedConversationID = nil
                restoreConversationDraft(nil)
                conversation = []
                finishConversationRead()
            }
        }
        let retained = Set(sessions.flatMap { $0.messages.map(\.id) } + conversation.map(\.id))
        sentAttachments = sentAttachments.filter { retained.contains($0.key) }

    }

    public func stopCurrentTask() {
        desktop.cancel()
        if isConnected { send(["op": .string("cancel")]) }
    }

    public func setNotificationsEnabled(_ enabled: Bool) async {
        guard enabled else {
            notificationsEnabled = false
            defaults.set(false, forKey: "notificationsEnabled")
            notificationMessage = nil
            return
        }
        guard notificationSupported else {
            notificationMessage = "系统通知需要从 Another You.app 启动。"
            return
        }
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            notificationsEnabled = granted
            defaults.set(granted, forKey: "notificationsEnabled")
            notificationMessage = granted ? nil : "通知权限未开启，可前往 macOS 系统设置调整。"
        } catch { notificationMessage = error.localizedDescription }
    }

    private func receive(_ message: AgentClientMessage) {
        defer {
            modelSettings.updateConnection(connected: isConnected, busy: hasPendingPrompt || hasActiveBackgroundAnalysis
                || cards.contains { $0.state == .running } || !pendingActions.isEmpty || updates.isInstalling)
            updates.installWhenIdle()
        }
        switch message {
        case .connection(let state):
            setIfChanged(\.connection, to: state)
            if case .failed(let error) = state { setIfChanged(\.statusMessage, to: error) }
            else { setIfChanged(\.statusMessage, to: state.label) }
            if state == .connected {
                if !hasSentLaunchSignal {
                    hasSentLaunchSignal = true
                    send(["op": .string("contextCapabilities"), "sources": .array([.string("work"), .string("notifications")])])
                    send(["op": .string("signal"), "signal": .object(["type": .string("event"), "name": .string("app-launched")])])
                }
                startIdleSampling()
            } else if state != .starting {
                proactiveContext.cancel()
                desktop.cancel()
                hasActiveBackgroundAnalysis = false
                idleTask?.cancel()
                pendingActions.removeAll()
                if !pendingConversationActions.isEmpty { conversationActionError = state.label }
                pendingConversationActions.removeAll()
                pendingConversationFork = nil
                finishConversationRead()
                isChangingPause = false
                for index in conversation.indices where conversation[index].isPending {
                    conversation[index].error = "Agent 连接已断开，请重新连接后重试。"
                }
            }
        case .protocolError(let error):
            statusMessage = error
            if isLoadingConversation { conversationActionError = error; finishConversationRead() }
            if let fork = pendingConversationFork {
                pendingConversationActions.remove(fork.sourceID)
                pendingConversationFork = nil
                conversationActionError = error
            }
        case .event(let event): consume(event)
        }
    }

    private func consume(_ event: AgentEvent) {
        if modelSettings.consume(event) { return }
        if event.kind == "context.request" || event.kind == "context.cancel" {
            guard !paused, !isShuttingDown, !isRestarting else { proactiveContext.cancel(); return }
            proactiveContext.handle(event) { [weak self] command in _ = self?.send(command) }
            return
        }
        if event.kind == "desktop.request" || event.kind == "desktop.cancel" {
            desktop.handle(event) { [weak self] command in _ = self?.send(command) }
            return
        }
        setIfChanged(\.lastUpdated, to: event.date)
        let payload = event.payload
        switch event.kind {
        case "agent.status":
            consumeSessions(payload)
            if let status = payload["proactive"]?.object { proactiveContext.update(status) }
            hasActiveBackgroundAnalysis = payload["proactive"]?.object?["running"]?.bool ?? false
            setIfChanged(\.paused, to: payload["paused"]?.bool ?? !(payload["schedulerEnabled"]?.bool ?? true))
            if paused { proactiveContext.cancel() }
            setIfChanged(\.isChangingPause, to: false)
            if let model = payload["model"]?.object {
                modelSettings.updateModelStatus(model)
                setIfChanged(\.modelConfigured, to: model["configured"]?.bool ?? false)
                setIfChanged(\.modelName, to: model["model"]?.string ?? "")
                setIfChanged(\.modelProvider, to: model["provider"]?.string ?? "")
                setIfChanged(\.reasoningEffort, to: model["reasoningEffort"]?.string ?? "")
                setIfChanged(\.modelMessage, to: model["message"]?.string ?? (modelConfigured ? "正在使用 Pi 模型" : "请在设置中选择模型并配置账户"))
            }
            if let proposals = payload["proposals"]?.array {
                setIfChanged(\.cards, to: proposals.compactMap { $0.object.flatMap { ProactiveCard(payload: $0) } }.sorted { $0.createdAt > $1.createdAt })
                setIfChanged(\.pendingActions, to: pendingActions.intersection(Set(cards.filter { $0.state == .pending }.map(\.id))))
            }
            if let past = payload["history"]?.array,
               let data = try? JSONEncoder().encode(past),
               let events = try? JSONDecoder().decode([AgentEvent].self, from: data) {
                mergeHistory(events)
            }
            if let records = payload["usageRecords"]?.array,
               let data = try? JSONEncoder().encode(records),
               let decoded = try? JSONDecoder().decode([UsageRecord].self, from: data) {
                setIfChanged(\.usageRecords, to: decoded)
            }
            setIfChanged(\.statusMessage, to: paused ? "主动建议已暂停" : "正在按节奏留意工作与通知")
        case "conversation.messages": consumeConversationMessages(payload)
        case "conversation.updated":
            consumeSessions(payload)
            if payload["action"]?.string == "fork", let fork = pendingConversationFork,
               payload["requestId"]?.string == fork.requestID, payload["sourceConversationId"]?.string == fork.sourceID,
               let id = payload["conversationId"]?.string, sessions.contains(where: { $0.id == id }) {
                pendingConversationFork = nil
                pendingConversationActions.remove(fork.sourceID)
                selectConversation(id)
            }
            if let values = payload["proposals"]?.array {
                setIfChanged(\.cards, to: values.compactMap { $0.object.flatMap { ProactiveCard(payload: $0) } }.sorted { $0.createdAt > $1.createdAt })
            }
            if let id = payload["conversationId"]?.string {
                pendingConversationActions.remove(id)
                if payload["action"]?.string == "delete" {
                    conversationDrafts.removeValue(forKey: id)
                    history.removeAll { $0.payload["conversationId"]?.string == id || $0.payload["suggestionId"]?.string == id }
                }
            }
        case "agent.activity", "agent.request": mergeHistory([event])
        case "agent.usage":
            var record = payload
            record["id"] = .string(event.id)
            record["occurredAt"] = .string(event.occurredAt)
            if let data = try? JSONEncoder().encode(record),
               let decoded = try? JSONDecoder().decode(UsageRecord.self, from: data),
               !usageRecords.contains(where: { $0.id == decoded.id }) {
                let cutoff = Date().addingTimeInterval(-30 * 86400)
                usageRecords = (usageRecords + [decoded]).filter { (AgentEvent.date(from: $0.occurredAt) ?? .distantPast) >= cutoff }
            }
        case "proactive.status":
            proactiveContext.update(payload)
            hasActiveBackgroundAnalysis = payload["running"]?.bool ?? false
        case "proactive.suggestion":
            if let card = ProactiveCard(payload: payload, event: event) {
                if let index = cards.firstIndex(where: { $0.id == card.id }) { cards[index] = card }
                else { cards.insert(card, at: 0) }
                statusMessage = "有一条新建议，等你决定。"
                notify(card)
            }
            mergeHistory([event])
        case "proposal.updated":
            if let id = payload["suggestionId"]?.string,
               let index = cards.firstIndex(where: { $0.id == id }) {
                if let state = payload["state"]?.string.flatMap(CardState.init(rawValue:)) { cards[index].state = state }
                cards[index].text = payload["text"]?.string
                cards[index].snoozedUntil = AgentEvent.date(from: payload["snoozedUntil"]?.string)
                pendingActions.remove(id)
                statusMessage = cards[index].state.label
            }
            mergeHistory([event])
        case "agent.response":
            if let requestID = payload["requestId"]?.string,
               let index = conversation.firstIndex(where: { $0.id == requestID }) {
                conversation[index].response = payload["text"]?.string ?? "模型返回了空响应。"
            }
            mergeHistory([event])
        case "agent.error":
            let error = payload["message"]?.string ?? "Agent 发生错误。"
            statusMessage = error
            if let requestID = payload["requestId"]?.string,
               let index = conversation.firstIndex(where: { $0.id == requestID }) { conversation[index].error = error }
            if let suggestionID = payload["suggestionId"]?.string { pendingActions.remove(suggestionID) }
            if let id = payload["conversationId"]?.string, pendingConversationActions.remove(id) != nil { conversationActionError = error }
            if let fork = pendingConversationFork, payload["requestId"]?.string == fork.requestID {
                pendingConversationActions.remove(fork.sourceID)
                pendingConversationFork = nil
                conversationActionError = error
            }
            if payload["readId"]?.string == conversationReadID, conversationReadID != nil { conversationActionError = error; finishConversationRead() }
            isChangingPause = false
            mergeHistory([event])
        default: break
        }
    }

    private func mergeHistory(_ events: [AgentEvent]) {
        let now = Date()
        var existing = Set(history.map(\.id))
        let additions = ActivityHistory.retained(events.filter { existing.insert($0.id).inserted }, now: now)
        let needsPruning = abs(now.timeIntervalSince(historyPrunedAt)) >= 60
        guard !additions.isEmpty || needsPruning else { return }
        let retained = needsPruning ? ActivityHistory.retained(history, now: now) : history
        if needsPruning { historyPrunedAt = now }
        setIfChanged(\.history, to: (retained + additions).sorted { $0.occurredAt > $1.occurredAt })
    }

    private func setIfChanged<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<AssistantStore, Value>, to value: Value) {
        if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
    }

    @discardableResult
    private func send(_ command: [String: JSONValue]) -> Bool {
        do { try agent.send(command); return true }
        catch { statusMessage = error.localizedDescription; return false }
    }

    private func startIdleSampling() {
        idleTask?.cancel()
        idleTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let seconds = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: UInt32.max)!)
                if seconds.isFinite, seconds >= 0 {
                    self.send(["op": .string("tick"), "idleForMs": .number(seconds * 1000)])
                }
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
            }
        }
    }

    private func notify(_ card: ProactiveCard) {
        guard notificationSupported, notificationsEnabled, !NSApplication.shared.isActive, !paused else { return }
        let content = UNMutableNotificationContent()
        content.title = card.title
        content.body = card.detail
        content.sound = .default
        let request = UNNotificationRequest(identifier: card.id, content: content, trigger: nil)
        Task { [weak self] in
            do { try await UNUserNotificationCenter.current().add(request) }
            catch { self?.notificationMessage = error.localizedDescription }
        }
    }
}
