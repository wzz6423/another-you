import Foundation

public enum JSONValue: Codable, Equatable, Sendable {
    case string(String), number(Double), bool(Bool), object([String: JSONValue]), array([JSONValue]), null

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode([String: JSONValue].self) { self = .object(value) }
        else { self = .array(try container.decode([JSONValue].self)) }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    public var string: String? { if case .string(let value) = self { value } else { nil } }
    public var bool: Bool? { if case .bool(let value) = self { value } else { nil } }
    public var object: [String: JSONValue]? { if case .object(let value) = self { value } else { nil } }
    public var array: [JSONValue]? { if case .array(let value) = self { value } else { nil } }
}

public struct AgentEvent: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let occurredAt: String
    public let kind: String
    public let source: String
    public let payload: [String: JSONValue]

    public var date: Date? { Self.date(from: occurredAt) }

    static func date(from string: String?) -> Date? {
        guard let string else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }
}

public enum CardKind: String, Codable, Sendable {
    case focus, wellbeing, idea, reminder

    public var label: String {
        switch self {
        case .focus: AppLocalization.text("专注")
        case .wellbeing: AppLocalization.text("休息")
        case .idea: AppLocalization.text("想法")
        case .reminder: AppLocalization.text("提醒")
        }
    }

    public var icon: String {
        switch self {
        case .focus: "scope"
        case .wellbeing: "leaf"
        case .idea: "lightbulb"
        case .reminder: "bell"
        }
    }
}

public enum CardState: String, Codable, Sendable {
    case pending, running, completed, snoozed, ignored, failed

    public var label: String { label(locale: AppLocalization.locale) }

    public func label(locale: Locale) -> String {
        switch self {
        case .pending: AppLocalization.string("待决定", locale: locale)
        case .running: AppLocalization.string("正在起草", locale: locale)
        case .completed: AppLocalization.string("草稿已就绪", locale: locale)
        case .snoozed: AppLocalization.string("稍后提醒", locale: locale)
        case .ignored: AppLocalization.string("已忽略", locale: locale)
        case .failed: AppLocalization.string("生成失败", locale: locale)
        }
    }
}

public enum CardAction: String, CaseIterable, Codable, Sendable {
    case execute, later, ignore

    public var label: String {
        switch self {
        case .execute: AppLocalization.text("生成草稿")
        case .later: AppLocalization.text("15 分钟后")
        case .ignore: AppLocalization.text("忽略")
        }
    }

    public var icon: String {
        switch self {
        case .execute: "pencil.line"
        case .later: "clock"
        case .ignore: "xmark"
        }
    }
}

public struct ProactiveCard: Identifiable, Equatable, Sendable {
    public let id: String
    public let kind: CardKind
    public let title: String
    public let detail: String
    public let rationale: String
    public let createdAt: Date
    public var state: CardState
    public var text: String?
    public var snoozedUntil: Date?
    public var archived: Bool
    public var pinned: Bool
    public var appName: String?
    public var usesLocalModel = false

    init?(payload: [String: JSONValue], event: AgentEvent? = nil) {
        guard let id = payload["suggestionId"]?.string ?? payload["id"]?.string ?? event?.id,
              let title = payload["title"]?.string else { return nil }
        self.id = id
        self.title = title
        detail = payload["summary"]?.string ?? payload["message"]?.string ?? ""
        let trigger = payload["trigger"]?.string
        kind = trigger == "idle" ? .wellbeing : .reminder
        rationale = payload["reason"]?.string ?? Self.reason(for: trigger)
        createdAt = AgentEvent.date(from: payload["createdAt"]?.string) ?? event?.date ?? Date()
        state = CardState(rawValue: payload["state"]?.string ?? "pending") ?? .pending
        text = payload["text"]?.string
        snoozedUntil = AgentEvent.date(from: payload["snoozedUntil"]?.string)
        archived = payload["archived"]?.bool ?? false
        pinned = payload["pinned"]?.bool ?? false
        appName = payload["context"]?.object?["appName"]?.string
        usesLocalModel = payload["context"]?.object?["executionRoute"]?.string == "local"
    }

    private static func reason(for trigger: String?) -> String {
        switch trigger {
        case "idle": "来自这台 Mac 的实际闲置时长。"
        case "time": "来自你设置的时间规则。"
        case "event": "来自应用启动事件。"
        default: "由本地规则触发，是否继续由你决定。"
        }
    }
}

public struct ConversationMessage: Identifiable, Equatable, Sendable {
    public let id: String
    public let prompt: String
    public var attachments: [ScreenAttachment] = []
    public var response: String?
    public var error: String?
    public var isPending: Bool { response == nil && error == nil }
}

public enum ConnectionState: Equatable, Sendable {
    case stopped, starting, connected, failed(String)

    public var label: String {
        switch self {
        case .stopped: AppLocalization.text("Agent 未启动")
        case .starting: AppLocalization.text("正在连接本地 Agent")
        case .connected: AppLocalization.text("本地 Agent 已连接")
        case .failed: AppLocalization.text("Agent 连接失败")
        }
    }
}

public struct ConversationForkOrigin: Equatable, Sendable {
    public let conversationID: String
    public let messageID: String
}

public struct ConversationSession: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let appName: String?
    public var updatedAt: Date
    public let createdAt: Date
    public let forkedFrom: ConversationForkOrigin?
    public var state: String
    public let archived: Bool
    public let pinned: Bool
    public var messages: [ConversationMessage]

    init(id: String, prompt: String, appName: String?, messages: [ConversationMessage]) {
        self.id = id
        title = String(prompt.prefix(100))
        self.appName = appName
        createdAt = Date()
        updatedAt = createdAt
        forkedFrom = nil
        state = "running"
        archived = false
        pinned = false
        self.messages = messages
    }

    init?(payload: [String: JSONValue]) {
        guard let id = payload["id"]?.string, let title = payload["title"]?.string else { return nil }
        self.id = id
        self.title = title
        appName = payload["appName"]?.string
        updatedAt = AgentEvent.date(from: payload["updatedAt"]?.string) ?? .distantPast
        createdAt = AgentEvent.date(from: payload["createdAt"]?.string) ?? updatedAt
        if let origin = payload["forkedFrom"]?.object,
           let conversationID = origin["conversationId"]?.string, let messageID = origin["messageId"]?.string {
            forkedFrom = ConversationForkOrigin(conversationID: conversationID, messageID: messageID)
        } else { forkedFrom = nil }
        state = payload["state"]?.string ?? "failed"
        archived = payload["archived"]?.bool ?? false
        pinned = payload["pinned"]?.bool ?? false
        messages = (payload["messages"]?.array ?? []).compactMap { value in
            guard let item = value.object, let id = item["id"]?.string, let prompt = item["prompt"]?.string else { return nil }
            return ConversationMessage(id: id, prompt: prompt, response: item["response"]?.string, error: item["error"]?.string)
        }
    }
}

public enum ActivityCategory: String, CaseIterable, Identifiable, Sendable {
    case all, thinking, execution, command, context, error
    public var id: String { rawValue }
    public var title: String { title(locale: AppLocalization.locale) }

    public func title(locale: Locale) -> String {
        AppLocalization.string(["all": "全部", "thinking": "思考", "execution": "执行", "command": "运行命令", "context": "读取应用上下文", "error": "错误"][rawValue]!, locale: locale)
    }
    public var icon: String {
        switch self {
        case .all: "list.bullet"
        case .thinking: "sparkle"
        case .execution: "play.circle"
        case .command: "terminal"
        case .context: "macwindow"
        case .error: "exclamationmark.triangle"
        }
    }
}

extension AgentEvent {
    public var activityCategory: ActivityCategory? {
        if kind == "agent.activity" { return payload["category"]?.string.flatMap(ActivityCategory.init(rawValue:)) }
        switch kind {
        case "agent.error": return .error
        case "agent.request", "agent.response", "proactive.suggestion", "proposal.updated": return .execution
        default: return nil
        }
    }

    public var activityTitle: String { activityTitle(locale: AppLocalization.locale) }

    public func activityTitle(locale: Locale) -> String {
        if kind == "agent.activity" {
            let category = activityCategory?.title(locale: locale) ?? AppLocalization.string("执行", locale: locale)
            let phase = payload["phase"]?.string ?? ""
            let label = AppLocalization.string(phase == "started" ? "开始" : phase == "failed" ? "失败" : "完成", locale: locale)
            return "\(category) · \(label)"
        }
        switch kind {
        case "proactive.suggestion": return payload["title"]?.string ?? AppLocalization.string("新的主动建议", locale: locale)
        case "proposal.updated": return payload["state"]?.string.flatMap(CardState.init(rawValue:))?.label(locale: locale) ?? AppLocalization.string("建议已更新", locale: locale)
        case "agent.request": return AppLocalization.string("收到消息", locale: locale)
        case "agent.response": return AppLocalization.string("模型回复已生成", locale: locale)
        case "agent.error": return AppLocalization.string("Agent 错误", locale: locale)
        default: return kind
        }
    }
}
