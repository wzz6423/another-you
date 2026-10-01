# CLI 与 JSONL 协议

[English](cli-reference.md) | **简体中文**

[Sidecar CLI](../agent-core/src/cli.ts) 从 stdin 读取命令、向 stdout 输出事件，每行一个 JSON 对象。它没有 HTTP 监听服务或独立通知命令，原生客户端使用同一协议。

## 启动与关闭

安装依赖后，从仓库根目录执行：

```bash
node --experimental-strip-types agent-core/src/cli.ts --stdio \
  --config "$HOME/Library/Application Support/AnotherYou/config.json"
```

| 参数 | 含义 |
| --- | --- |
| `--stdio` | 必需，使用 JSON Lines 模式。 |
| `--config PATH` | 可选配置路径，默认是平台数据目录下的 `config.json`。 |

CLI 恢复状态、启动已启用的调度、检查当前时间、发出 `app-launched` 信号，并输出 `agent.status`。启动建议受暂停状态、已有建议和冷却限制，启动时不验证模型可用性。

发送 `{"op":"shutdown"}` 关闭。EOF、SIGINT 和 SIGTERM 也会停止调度并取消正在进行的模型请求，进程等待该任务完成清理。致命启动错误写入 stderr，并以状态码 1 退出；命令错误发出 `agent.error`，通常不结束进程。

## 命令参考

| `op` | 字段 | 行为 |
| --- | --- | --- |
| `status` | 无 | 输出 `agent.status`。 |
| `prompt` | `requestId`、`prompt` | 发出请求事件，随后输出回复或错误。 |
| `decide` | `suggestionId`、`decision`；可选 `snoozeMinutes` | 生成草稿、稍后或忽略建议。 |
| `pause` / `resume` | 无 | 持久化暂停状态，输出调度与 Agent 状态；暂停不取消已提交的模型请求。 |
| `signal` | `signal`；可选 `now` | 接收时间、事件或闲置信号。 |
| `tick` | 可选 `now`、`idleForMs` | 恢复到期的稍后建议并检查时间/闲置规则。 |
| `addRule` | `rule` | 新增或按相同 ID 替换规则，并持久化。 |
| `removeRule` | `ruleId` | 删除规则并持久化剩余规则；已有建议保留。 |
| `shutdown` | 无 | 停止调度、取消当前请求并退出。 |

`requestId` 是最长 256 字符的非空字符串，每次提问应使用新 ID；若保留历史里已有该 ID 的完成回复，会拒绝重复请求。`prompt` 必须为非空白文本，最多 50,000 字符。命令行最多 1,000,000 字符。空行会忽略，数组等非对象 JSON 会被拒绝。

`now` 和信号 `at` 必须是有效日期字符串，主动提供时应包含时区。`idleForMs` 是有限非负数。正常使用应省略模拟时间戳，并报告真实测量的闲置时长。调度禁用或暂停时不处理信号和到期稍后建议，直接提问与用户决定仍可使用。

同时只允许一个 `prompt` 或 `decide/execute` 模型请求。新的同类命令立即报错，不进入队列。状态、暂停/恢复、稍后/忽略和关闭仍可处理。请求最多运行 60 秒，不隐式重试。协议没有单独取消请求的命令，也不输出逐 token 事件。

规则编辑和 signal/tick 没有通用确认事件。通过 `status` 检查规则变化；一个信号未产生建议也可能是正常结果。

## 输入示例

下列每一行都是完整命令，请在合适时机输入下一条；提问后立即发送 shutdown 会取消该请求。

```jsonl
{"op":"status"}
{"op":"prompt","requestId":"question-001","prompt":"帮我梳理今天的一个优先事项。"}
{"op":"pause"}
{"op":"resume"}
```

从 `proactive.suggestion` 的 `payload.suggestionId`，或 `agent.status.payload.proposals` 的 `id` 复制真实建议 ID，替换下方 `SUGGESTION_ID`，选择其中一种决定：

```jsonl
{"op":"decide","suggestionId":"SUGGESTION_ID","decision":"execute"}
{"op":"decide","suggestionId":"SUGGESTION_ID","decision":"later","snoozeMinutes":15}
{"op":"decide","suggestionId":"SUGGESTION_ID","decision":"ignore"}
```

`execute` 只生成供审阅的文本，不执行外部动作。`later` 默认 15 分钟，允许 1 到 1440 之间的有限数值。到期建议使用原建议 ID 和新的事件 ID 恢复。`ignore` 将建议标为已忽略。

## 规则与信号

| 内置规则 | 触发 | 冷却 |
| --- | --- | --- |
| `welcome` | 事件 `app-launched` | 24 小时 |
| `morning` | 本地时间 `09:00` | 20 小时 |
| `idle` | 闲置至少 900,000 ms（15 分钟） | 2 小时 |

默认去重窗口为 300,000 ms。同一规则还需等待已有待处理/执行中/稍后/失败建议解决。核心默认每 30 秒检查时间，不自行推断设备闲置；Swift 宿主每 30 秒提供真实闲置测量。

每条规则都需要 `id`、`type`、`title` 和 `message`，可选 `enabled`（默认 `true`）、`context`、`cooldownMs` 和 `dedupeWindowMs`。规则时长须为有限非负数。不同类型还需要：

| 规则类型 | 字段 | 匹配方式 |
| --- | --- | --- |
| `time` | `at` 为 `HH:mm`；可选 `daysOfWeek` 数组 | 匹配本地分钟及可选星期，周日 `0` 至周六 `6`；不补发错过的时间。 |
| `event` | `eventName` | 与信号 `name` 精确匹配。 |
| `idle` | `minIdleMs` | 测量的 `idleForMs` 达到阈值。 |

事件规则与对应输入信号示例：

```jsonl
{"op":"addRule","rule":{"id":"focus-ended","type":"event","eventName":"focus-ended","title":"休息片刻","message":"要生成一份简短的恢复清单吗？","cooldownMs":1800000}}
{"op":"signal","signal":{"type":"event","name":"focus-ended","payload":{}}}
{"op":"status"}
```

此例由调用方提供事件，不是已实现的专注会话连接器。信号包含 `type`，可选 `at` 和 `dedupeKey`；事件信号还包含 `name` 与可选 `payload`，闲置信号包含 `idleForMs`，时间信号没有其他必填字段。规则 `context` 会成为建议/模型上下文；事件 `payload` 作为信号数据记录，不会自动成为模型上下文。

规则存在 `state.json` 中，不属于配置 schema，由 `addRule`/`removeRule` 持久化。冷却和去重跨重启保留，去重键保存为 SHA-256 摘要。规则上下文与记录的信号仍受内容保存策略控制。

## 输出事件

每条事件含 `id`、`occurredAt`（ISO 时间戳）、`kind`、`source` 和 `payload`，部分事件还带 `dedupeKey`。来源为 `scheduler`、`agent` 或 `system`。

| `kind` | 主要 payload 字段 |
| --- | --- |
| `agent.status` | `configPath`、`paused`、`schedulerEnabled`、`model`、`rules`、`proposals`、`history` |
| `scheduler.status` | `running`，部分事件带 `paused` |
| `proactive.suggestion` | `suggestionId`、`ruleId`、`title`、`message`、`summary`、`reason`、`createdAt`、`state`、`trigger`、`context`、`signal` |
| `agent.request` | `requestId`、`prompt` |
| `agent.response` | `requestId`、`text`、`model` |
| `proposal.updated` | `suggestionId`、`decision`、`state`；可选 `text`、`snoozedUntil` |
| `agent.error` | `message`，适用时带 `requestId` 或 `suggestionId` |

事件类型联合中有 `scheduler.signal`，但当前默认命令流程不会发出它。模型任务完成或失败后都会再输出状态。模型状态含 `configured`、`available`、`endpoint`、`model` 和 `message`，含义见 [配置参考](configuration.zh-CN.md)。

始终使用 `payload.suggestionId` 作为建议的稳定身份。外层 `id` 只代表单次事件，不能在稍后建议恢复时据此新增第二张卡片。状态快照中的建议使用 `id`，还包含 `ruleId`、`title`、`summary`、`reason`、`createdAt`、`state`、`context`，以及可选 `text`/`snoozedUntil`。

## 建议状态

| 状态 | 含义 / 后续动作 |
| --- | --- |
| `pending` | 等待用户决定。 |
| `running` | 正在生成草稿，拒绝进一步处理。 |
| `completed` | 草稿已生成，拒绝重复处理。 |
| `snoozed` | 等待到期，用户也可提前处理。 |
| `ignored` | 已忽略，拒绝重复处理。 |
| `failed` | 生成失败或中断，用户可重试、稍后或忽略。 |

`execute` 先发出 `running`，随后为带文本的 `completed`，或带错误文本的 `failed`；失败时还会发出 `agent.error`。客户端应依据这些事件或后续状态快照判断成功，重启后不会自动重试。完整流程见 [架构](architecture.zh-CN.md)，持久化限制见 [配置参考](configuration.zh-CN.md)。
