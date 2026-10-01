# Another You 架构

## 目标

让个人助手在“该出现的时候”主动提出下一步，并且让用户能看懂它为什么出现、准备做什么以及如何撤销。

## 分层

```text
SwiftUI macOS
  ├─ 今日视图 / 主动卡片 / 时间线 / 设置
  └─ AgentClient 协议
       │ 本地 IPC 或 loopback HTTP（后续接入）
Agent Core
  ├─ SignalSource：时间、日历、文件、应用状态等事件
  ├─ ProactiveScheduler：优先级、冷却、去重、免打扰
  ├─ ProposalStore：建议、审批、执行状态和审计事件
  ├─ PrivacyPolicy：本地数据目录、连接器范围、敏感应用黑名单
  └─ PiAdapter：锁定上游 commit，加载私有扩展、技能和提示词
       │
Pi coding agent（本地 checkout）
  └─ 模型供应商或本地模型
```

## 主动式行为约束

- 只在事件影响当前决策且置信度足够时产生建议。
- 同一个建议在冷却窗口内只出现一次；用户忽略后需要更长的退避时间。
- 建议默认是 `suggest`，执行外部副作用前必须变成 `approved`。
- 所有建议都记录来源信号、解释、风险级别和最终结果。
- “后台运行”只负责准备上下文和草稿；发送、删除、付款、提交代码等动作由 UI 明确确认。

## 与 Today / Antigravity 的取舍

- 借鉴 Today 的短简报、可编辑长期记忆和确认后执行。
- 借鉴 Antigravity 的异步任务、计划任务、子 Agent 和产物审阅。
- 第一版保持单用户、单 macOS、本地优先，先把信任链做完整，再增加连接器和跨设备同步。
