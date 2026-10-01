import Combine
import Foundation

@MainActor
public final class AssistantStore: ObservableObject {
    @Published public private(set) var cards: [ProactiveCard]
    @Published public private(set) var lastUpdated: Date
    @Published public private(set) var statusMessage: String

    private let agent: any AgentClient

    public init(client: any AgentClient = MockAgentClient()) {
        self.agent = client
        self.cards = client.loadToday()
        self.lastUpdated = Date()
        self.statusMessage = "本地 Agent 已就绪"
    }

    public var completedCount: Int {
        cards.filter { $0.state == .done }.count
    }

    public var pendingCount: Int {
        cards.filter { $0.state == .pending }.count
    }

    public var nextDueDate: Date? {
        cards
            .filter { $0.state == .pending || $0.state == .scheduled }
            .map(\.dueDate)
            .min()
    }

    public func refresh() {
        cards = agent.loadToday()
        lastUpdated = Date()
        statusMessage = "已更新今日建议"
    }

    public func apply(_ action: CardAction, to card: ProactiveCard) {
        guard let index = cards.firstIndex(where: { $0.id == card.id }) else { return }

        switch action {
        case .execute:
            cards[index].state = .done
            statusMessage = "已执行：\(card.title)"
        case .later:
            cards[index].state = .scheduled
            statusMessage = "已安排稍后提醒"
        case .ignore:
            cards[index].state = .dismissed
            statusMessage = "已忽略这条建议"
        }

        lastUpdated = Date()
    }
}
