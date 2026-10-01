import Foundation

public protocol AgentClient: Sendable {
    func loadToday() -> [ProactiveCard]
}

public struct MockAgentClient: AgentClient, Sendable {
    private let now: Date

    public init(now: Date = Date()) {
        self.now = now
    }

    public func loadToday() -> [ProactiveCard] {
        [
            ProactiveCard(
                kind: .focus,
                title: "把今天最重要的一件事推进 25 分钟",
                detail: "你上午连续处理了几条零散消息，注意力正在被切碎。",
                suggestion: "我可以帮你打开专注计时，并把通知静音。",
                rationale: "根据你今天的安排，10:30–11:00 是一段完整的空档。",
                dueDate: now.addingTimeInterval(30 * 60),
                duration: "25 分钟",
                priority: .high
            ),
            ProactiveCard(
                kind: .wellbeing,
                title: "该离开屏幕，走动一下了",
                detail: "你已经连续工作 86 分钟，肩颈和眼睛都需要一次短暂恢复。",
                suggestion: "我会在 5 分钟后提醒你，并暂停当前专注计时。",
                rationale: "连续工作超过 75 分钟时，短暂走动能帮你找回能量。",
                dueDate: now.addingTimeInterval(75 * 60),
                duration: "5 分钟",
                priority: .medium
            ),
            ProactiveCard(
                kind: .idea,
                title: "把昨晚的灵感收进项目",
                detail: "你的备忘录里有一条关于「主动式日程」的想法，还没有归档。",
                suggestion: "我可以整理成一个项目笔记，保留原文和下一步。",
                rationale: "这条笔记和你最近持续推进的个人 AI 助手高度相关。",
                dueDate: now.addingTimeInterval(3 * 60 * 60),
                duration: "10 分钟",
                priority: .low
            ),
            ProactiveCard(
                kind: .reminder,
                title: "下午 4 点前确认本周计划",
                detail: "周五的同步会议需要一份简短的进度更新。",
                suggestion: "我可以先生成一个三点式提纲，等你确认后再发送。",
                rationale: "距离会议还有 6 小时，提前准备能减少临时切换。",
                dueDate: now.addingTimeInterval(6 * 60 * 60),
                duration: "8 分钟",
                priority: .medium
            )
        ]
    }
}
