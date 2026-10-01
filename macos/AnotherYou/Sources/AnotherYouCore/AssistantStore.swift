import AppKit
import Combine
import CoreGraphics
import Foundation
import UserNotifications

@MainActor
public final class AssistantStore: ObservableObject {
    @Published public private(set) var cards: [ProactiveCard] = []
    @Published public private(set) var history: [AgentEvent] = []
    @Published public private(set) var conversation: [ConversationMessage] = []
    @Published public private(set) var lastUpdated: Date?
    @Published public private(set) var statusMessage = "Agent 未启动"
    @Published public private(set) var connection: ConnectionState = .stopped
    @Published public private(set) var paused = false
    @Published public private(set) var isChangingPause = false
    @Published public private(set) var isRestarting = false
    @Published public private(set) var modelConfigured = false
    @Published public private(set) var modelMessage = "请在设置中连接本地模型。"
    @Published public private(set) var settings: AgentSettings
    @Published public private(set) var pendingActions: Set<String> = []
    @Published public private(set) var notificationsEnabled: Bool
    @Published public private(set) var notificationMessage: String?
    @Published public private(set) var settingsError: String?

    private let agent: any AgentClient
    private let repository: AgentSettingsRepository
    private let defaults: UserDefaults
    private var idleTask: Task<Void, Never>?
    private var hasSentLaunchSignal = false

    public init(
        client: any AgentClient = ProcessAgentClient(),
        repository: AgentSettingsRepository = AgentSettingsRepository(),
        defaults: UserDefaults = .standard
    ) {
        self.agent = client
        self.repository = repository
        self.defaults = defaults
        notificationsEnabled = defaults.bool(forKey: "notificationsEnabled")
        do { settings = try repository.load() }
        catch {
            settings = AgentSettings()
            settingsError = "无法读取配置：\(error.localizedDescription)"
        }
        agent.onMessage = { [weak self] message in self?.receive(message) }
    }

    public var isConnected: Bool { connection == .connected }
    public var completedCount: Int { cards.filter { $0.state == .completed }.count }
    public var pendingCount: Int { cards.filter { $0.state == .pending }.count }
    public var hasPendingPrompt: Bool { conversation.contains(where: \.isPending) }
    public var notificationSupported: Bool {
        Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil
    }
    public var activeCards: [ProactiveCard] { cards.filter { $0.state != .ignored } }
    public var nextDueDate: Date? { cards.filter { $0.state == .snoozed }.compactMap(\.snoozedUntil).min() }
    public var activityHistory: [AgentEvent] {
        history.filter { ["proactive.suggestion", "proposal.updated", "agent.response", "agent.error"].contains($0.kind) }
    }

    public func connect() {
        guard !isConnected, connection != .starting, !isRestarting else { return }
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
        idleTask?.cancel()
        await agent.stop()
    }

    public func togglePause() {
        guard isConnected, !isChangingPause else { return }
        isChangingPause = true
        if !send(["op": .string(paused ? "resume" : "pause")]) { isChangingPause = false }
    }

    public func apply(_ action: CardAction, to card: ProactiveCard) {
        guard isConnected, !pendingActions.contains(card.id),
              card.state == .pending || card.state == .failed || card.state == .snoozed else { return }
        if action == .execute && !modelConfigured {
            statusMessage = "请先在设置中连接本地模型。"
            return
        }
        pendingActions.insert(card.id)
        if !send(["op": .string("decide"), "suggestionId": .string(card.id), "decision": .string(action.rawValue)]) {
            pendingActions.remove(card.id)
        }
    }

    @discardableResult
    public func ask(_ prompt: String) -> Bool {
        let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, isConnected, modelConfigured, !hasPendingPrompt else { return false }
        let id = UUID().uuidString
        conversation.append(ConversationMessage(id: id, prompt: prompt))
        if !send(["op": .string("prompt"), "requestId": .string(id), "prompt": .string(prompt)]) {
            conversation[conversation.count - 1].error = statusMessage
            return false
        }
        return true
    }

    public func saveSettings(_ settings: AgentSettings) async -> Bool {
        guard !isRestarting else { return false }
        do {
            let validated = try settings.validated()
            try repository.save(validated)
            self.settings = validated
            settingsError = nil
            isRestarting = true
            idleTask?.cancel()
            await agent.stop()
            isRestarting = false
            connect()
            return true
        } catch {
            settingsError = error.localizedDescription
            return false
        }
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
        switch message {
        case .connection(let state):
            connection = state
            statusMessage = state.label
            if case .failed(let error) = state { statusMessage = error }
            if state == .connected {
                if !hasSentLaunchSignal {
                    hasSentLaunchSignal = true
                    send(["op": .string("signal"), "signal": .object(["type": .string("event"), "name": .string("app-launched")])])
                }
                startIdleSampling()
            } else if state != .starting {
                idleTask?.cancel()
                pendingActions.removeAll()
                isChangingPause = false
                for index in conversation.indices where conversation[index].isPending {
                    conversation[index].error = "Agent 连接已断开，请重新连接后重试。"
                }
            }
        case .protocolError(let error): statusMessage = error
        case .event(let event): consume(event)
        }
    }

    private func consume(_ event: AgentEvent) {
        lastUpdated = event.date
        let payload = event.payload
        switch event.kind {
        case "agent.status":
            paused = payload["paused"]?.bool ?? !(payload["schedulerEnabled"]?.bool ?? true)
            isChangingPause = false
            if let model = payload["model"]?.object {
                modelConfigured = model["configured"]?.bool ?? false
                let name = model["model"]?.string ?? settings.model
                modelMessage = model["message"]?.string ?? (modelConfigured ? "本地模型：\(name)" : "请在设置中连接本地模型。")
            }
            if let proposals = payload["proposals"]?.array {
                cards = proposals.compactMap { $0.object.flatMap { ProactiveCard(payload: $0) } }.sorted { $0.createdAt > $1.createdAt }
                pendingActions.formIntersection(Set(cards.filter { $0.state == .pending }.map(\.id)))
            }
            if let past = payload["history"]?.array,
               let data = try? JSONEncoder().encode(past),
               let events = try? JSONDecoder().decode([AgentEvent].self, from: data) {
                mergeHistory(events)
            }
            statusMessage = paused ? "主动建议已暂停" : "正在留意时间与闲置状态"
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
            isChangingPause = false
            mergeHistory([event])
        default: break
        }
    }

    private func mergeHistory(_ events: [AgentEvent]) {
        var existing = Set(history.map(\.id))
        history += events.filter { existing.insert($0.id).inserted }
        history.sort { $0.occurredAt > $1.occurredAt }
        if history.count > 200 { history = Array(history.prefix(200)) }
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
