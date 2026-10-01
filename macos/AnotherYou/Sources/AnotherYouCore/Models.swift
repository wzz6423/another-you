import Foundation

public enum CardKind: String, CaseIterable, Codable, Sendable {
    case focus
    case wellbeing
    case idea
    case reminder

    public var label: String {
        switch self {
        case .focus: "专注"
        case .wellbeing: "状态"
        case .idea: "灵感"
        case .reminder: "提醒"
        }
    }

    public var icon: String {
        switch self {
        case .focus: "scope"
        case .wellbeing: "sun.max.fill"
        case .idea: "sparkles"
        case .reminder: "bell.fill"
        }
    }
}

public enum CardPriority: Int, Codable, Sendable {
    case low = 1
    case medium = 2
    case high = 3

    public var label: String {
        switch self {
        case .low: "可稍后"
        case .medium: "建议处理"
        case .high: "现在值得"
        }
    }
}

public enum CardState: String, Codable, Sendable {
    case pending
    case scheduled
    case done
    case dismissed

    public var label: String {
        switch self {
        case .pending: "待处理"
        case .scheduled: "已安排"
        case .done: "已完成"
        case .dismissed: "已忽略"
        }
    }
}

public enum CardAction: String, CaseIterable, Codable, Sendable {
    case execute
    case later
    case ignore

    public var label: String {
        switch self {
        case .execute: "执行"
        case .later: "稍后"
        case .ignore: "忽略"
        }
    }

    public var icon: String {
        switch self {
        case .execute: "play.fill"
        case .later: "clock"
        case .ignore: "xmark"
        }
    }
}

public struct ProactiveCard: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let kind: CardKind
    public let title: String
    public let detail: String
    public let suggestion: String
    public let rationale: String
    public let dueDate: Date
    public let duration: String
    public let priority: CardPriority
    public var state: CardState

    public init(
        id: UUID = UUID(),
        kind: CardKind,
        title: String,
        detail: String,
        suggestion: String,
        rationale: String,
        dueDate: Date,
        duration: String,
        priority: CardPriority,
        state: CardState = .pending
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.detail = detail
        self.suggestion = suggestion
        self.rationale = rationale
        self.dueDate = dueDate
        self.duration = duration
        self.priority = priority
        self.state = state
    }
}
