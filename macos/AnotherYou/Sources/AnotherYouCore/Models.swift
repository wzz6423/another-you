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
        case .focus: "专注"
        case .wellbeing: "休息"
        case .idea: "想法"
        case .reminder: "提醒"
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

    public var label: String {
        switch self {
        case .pending: "待决定"
        case .running: "正在起草"
        case .completed: "草稿已就绪"
        case .snoozed: "稍后提醒"
        case .ignored: "已忽略"
        case .failed: "生成失败"
        }
    }
}

public enum CardAction: String, CaseIterable, Codable, Sendable {
    case execute, later, ignore

    public var label: String {
        switch self {
        case .execute: "生成草稿"
        case .later: "15 分钟后"
        case .ignore: "忽略"
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
    public var response: String?
    public var error: String?
    public var isPending: Bool { response == nil && error == nil }
}

public enum ConnectionState: Equatable, Sendable {
    case stopped, starting, connected, failed(String)

    public var label: String {
        switch self {
        case .stopped: "Agent 未启动"
        case .starting: "正在连接本地 Agent"
        case .connected: "本地 Agent 已连接"
        case .failed: "Agent 连接失败"
        }
    }
}
