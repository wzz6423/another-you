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

CLI 恢复状态、启动已启用的调度、检查当前时间、发出 `app-launched` 信号，并输出 `agent.status`。应用不再内置欢迎会话；用户自定义启动规则仍可接收该信号。建议受暂停状态、已有建议和冷却限制，启动时不验证模型可用性。

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
| `contextCapabilities` | `sources` | 宿主声明可提供的 `work`、`notifications` 采集来源。 |
| `contextResult` | `contextResult` | 宿主返回带 `requestId` 的异步采集结果；迟到或不匹配的回执会被丢弃。 |
| `addRule` | `rule` | 新增或按相同 ID 替换规则，并持久化。 |
| `removeRule` | `ruleId` | 删除规则并持久化剩余规则；已有建议保留。 |
| `shutdown` | 无 | 停止调度、取消当前请求并退出。 |

`requestId` 是最长 256 字符的非空字符串，每次提问应使用新 ID；若保留历史里已有该 ID 的完成回复，会拒绝重复请求。`prompt` 必须为非空白文本，最多 50,000 字符。命令行最多 1,000,000 字符。空行会忽略，数组等非对象 JSON 会被拒绝。

`now` 和信号 `at` 必须是有效日期字符串，主动提供时应包含时区。`idleForMs` 是有限非负数。正常使用应省略模拟时间戳，并报告真实测量的闲置时长。调度禁用或暂停时不处理信号和到期稍后建议，直接提问与用户决定仍可使用。

不同 `conversationId` 的 `prompt` 可同时运行，各自保留历史与取消信号；同一会话的重复发送立即报错，不进入队列。建议执行也保留独立运行状态。状态、暂停/恢复、稍后/忽略和关闭仍可处理。单次模型 HTTP 请求最多 60 秒，整个工具循环最多 180 秒，不隐式重试。`cancel` 携带 `conversationId` 时只取消对应会话的模型和工具；省略时取消全部活动请求。退出同样会取消并等待所有请求结束。不输出逐 token 事件。截图附件和电脑工具回执见[操作协议](desktop-automation.zh-CN.md#协议与开发验证)。

规则编辑和 signal/tick 没有通用确认事件。通过 `status` 检查规则变化；一个信号未产生建议也可能是正常结果。

## 模型配置与认证协议

以下命令均携带独立的 `requestId`：

| `op` | 字段 | 行为 |
| --- | --- | --- |
| `modelCatalog` | 可选 `refresh: true` | 读取本地模型目录；显式刷新时请求已配置提供方的目录。 |
| `modelSelect` | `provider`、`model`；可选 `thinkingLevel`、`accountName` | 保存 Pi 默认模型与受支持的思考深度。 |
| `modelConfigure` | `provider`、`baseUrl`、`api`、`model`；可选 `apiKey`、`thinkingLevel`、`accountId`、`accountName`、`newAccount` | 校验并合并 API 配置，单独保存密钥并选择模型；支持 `openai-completions`、`openai-responses`、`anthropic-messages`。省略或留空密钥仅保留已有可用 API key 凭据，保存不验证连接。 |
| `modelTest` | 无 | 向保存的模型发送无工具、无会话上下文的短请求，回传实际连接结果。 |
| `modelLogin` | `provider`、`authType: api_key / oauth`；可选 `accountId`、`accountName`、`newAccount` | 启动 Pi 认证交互。 |
| `modelAuthReply` | 登录的 `requestId`、`promptId`、`value` | 回复当前认证问题；text 按 prompt.required 校验，可选文本允许空字符串；secret / manual_code 不接受空白，select 必须匹配选项。非选择项输入提交前会去掉首尾空白。错误或过期的 prompt 不结束原登录。 |
| `modelAuthCancel` | 当前操作的 `requestId` | 取消账户操作或目录刷新。 |
| `modelLogout` | `provider`；可选 `accountId` | 清除指定账户的凭据（默认当前账户），保留账户配置。 |
| `modelImport` | 可选 `path`（绝对路径） | 默认从 Pi 标准目录自动导入模型定义与默认选择，保留本地已有配置，不导入凭据。显式路径仍接受 `models.json` 或其目录。 |
| `modelAccountSelect` | `accountId` | 切换账户及其完整模型配置。 |
| `modelAccountDelete` | `accountId` | 删除指定账户；删除当前账户时使用同提供方的剩余账户（如有）。 |
| `modelCredentialRead` | `accountId` | 显式读取该账户已保存的 API Key，仅通过 `model.credential` 即时回传。 |

`modelConfigure` 与 `modelLogin` 默认更新当前账户；传 `newAccount: true` 新建，传 `accountId` 指定已有账户，两者不能并用。`accountName` 是可选的非空名称，最长 120 字符。配置、凭据及每账户目录缓存保存在 `<dataDir>/pi/models.sqlite`。

`model.catalog` 返回 `models`、`providers`、可选 `selected` 与 `message`。支持 API 表单的提供方另含 `apiConfiguration: { baseUrl, api }`，地址不携带凭据、查询参数或片段，不返回密钥。`model.operation` 返回 `operation` 和 `state`（`started`、`succeeded`、`failed`、`cancelled`）；发送命令不代表保存成功。`model.auth` 使用 `stage` 表示 `prompt`、`promptResolved`、`promptCancelled` 或 `notify`，并携带 `requestId`、`provider`。prompt 类型遵循 Pi：`text`、`secret`、`manual_code`、`select`，选择项提交其 `id`。

`model.catalog.accounts` 包含 `id`、`provider`、`name`、`hasAPIKey` 和可选 `credentialType`；提供方的 `accountId` 标记当前账户，不包含密钥。`model.credential` 仅包含 `requestId`、`accountId`、`apiKey`，客户端应核对请求及账户，离开查看状态时清除密钥；读取失败沿用 `model.operation` 的 `failed` 回执。该事件不进入 EventBus 或持久化历史。

模型修改、登录、刷新和连接测试互斥，并与模型请求互斥；本地目录读取仍可用。认证操作最长 10 分钟，目录刷新最长 20 秒，连接测试最长 60 秒并可通过 `modelAuthCancel` 取消。EOF、关闭或断开会取消等待中的认证与连接测试。认证内容仅即时传输，不进入 EventBus、会话和状态历史。真实提供方登录和模型兼容性需要另行验证。

## 会话与活动协议

`prompt` 可选 `conversationId`，省略时兼容 `default` 会话，各会话隔离上下文。`conversationAction` 要求 `conversationId` 和 `action`（`archive`、`unarchive`、`delete`、`pin`、`unpin`）；执行中的会话和建议拒绝这些操作。保存成功后才发出 `conversation.updated`，含 `conversationId`、可选 `action`、`conversations` 和 `proposals`；失败事件 `agent.error` 带 `conversationId`，已确认的状态保持不变。会话和建议的置顶状态独立于归档状态持久化，不改变原时间；旧存档缺少 `pinned` 时默认为 `false`。已置顶建议不参与已完成和已忽略建议的自动清理。

`conversationFork` 要求 `conversationId`、独立 `requestId`，可选 `messageId`。省略起点时复制全部轮次，指定时复制该轮及之前的完整前缀，保留消息 ID。分支保存为新的独立会话，记录 `forkedFrom: { conversationId, messageId }`，不修改源会话、不调用模型或重复计入用量；执行中拒绝分支。成功回执为 `conversation.updated`，含 `action: "fork"`、`requestId`、`sourceConversationId` 及新会话的 `conversationId`。客户端仅在匹配成功回执后切换并按需读取完整消息；保存失败不创建会话，错误携带源 `conversationId` 和 `requestId`。

`agent.status.payload.conversations` 包含 `id`、`title`、可选 `appName`、`createdAt`、`updatedAt`、`state`、`archived` 和 `pinned`；消息通过下文的按需读取协议返回。重启恢复遵循 `privacy.storePrompts` / `privacy.storeResponses`；截图二进制不持久化。`agent.activity` 记录 `category`（`thinking`、`execution`、`command`、`context`）、`phase`（`started`、`completed`、`failed`）、可选 `toolName` 和 `source`，不传输思考正文。新记录另含 `runId`、实际应用与窗口、工具 `action`/`toolCallId`、限长且遮盖密钥的 `input`/`result`、判定原因、耗时与模型调用元数据。直接请求的活动与用量事件附带实际 `conversationId` / `requestId`，建议执行附带 `suggestionId`，旧事件不按时间猜测归属。

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
| `morning` | 本地时间 `09:00` | 20 小时 |
| `idle` | 闲置至少 900,000 ms（15 分钟） | 2 小时 |

升级时停用未修改的旧 `welcome` 规则。只有原始启动事件仍在历史中、没有用户决策或归档操作记录的待处理样例才会清理；修改过的规则、真实用户会话、已置顶或已处理的建议及缺少识别历史的卡片均保留。

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
| `agent.status` | `configPath`、`paused`、`schedulerEnabled`、`model`、`proactive`、`rules`、`proposals`、`history`、`usageRecords`、`activityRecords` |
| `scheduler.status` | `running`，部分事件带 `paused` |
| `proactive.status` | `taskId`、`running`、`tasks`、`sources`、`intervals` |
| `context.request` / `context.cancel` | `requestId`、`source`；请求或取消工作/通知采集 |
| `proactive.suggestion` | `suggestionId`、`ruleId`、`title`、`message`、`summary`、`reason`、`createdAt`、`state`、`trigger`、`context`、`signal` |
| `agent.request` | `requestId`、`conversationId`、`prompt`、可选 `appName` |
| `activity.recorded` | `kind`（`prompt` / `suggestion`）、可选 `appName`；外层 `id`、`occurredAt` 为统计记录的身份和时间 |
| `agent.usage` | `source`、`model`、`outcome`、可选 `usage`、`reasoningEffort`、`toolCalls` |
| `agent.response` | `requestId`、`text`、`model` |
| `proposal.updated` | `suggestionId`、`decision`、`state`；可选 `text`、`snoozedUntil` |
| `agent.error` | `message`，适用时带 `requestId` 或 `suggestionId` |

事件类型联合中有 `scheduler.signal`，但当前默认命令流程不会发出它。模型任务完成或失败后都会再输出状态。模型状态含 `configured`、`available`、`endpoint`、`model`、`provider`、`reasoningEffort`、`configDirectory` 和 `message`，含义见 [配置参考](configuration.zh-CN.md)。

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

用量记录独立保留最近 30 天。`usage` 包括 `inputTokens`、`outputTokens`、`cacheReadTokens`、`cacheWriteTokens`、`totalTokens`；未报告时省略。`outcome` 为 `completed` 或 `failed`，失败已报告的消耗也计入。`toolCalls` 每项包含 `name` 和 `kind`（`tool` / `plugin` / `skill` / `mcp`）。当前内置文件、Shell 和网络工具，未接入的扩展不会产生虚构记录。主会话携带最近 20 轮成功对话上下文，与建议独立，重启不恢复。


### 会话按需读取与大消息传输

`agent.status` 和 `conversation.updated` 的 `conversations` 只含会话摘要，不重复发送全部消息。打开会话时发送 `{"op":"conversationRead","conversationId":"…","readId":"…"}`，回执 `conversation.messages` 包含相同 ID 和完整 `conversation`。读取回执不保存到活动记录；客户端忽略旧 `readId` 的迟到回执。

普通事件仍是一行 JSON。UTF-8 编码超过 3 MiB 的事件会由 `encodeEvent` 透明拆成 `protocol.chunk`；每块 payload 包含 `eventId`、从 0 开始的 `index`、`total` 与 base64 `data`（每块原始字节最多 128 KiB）。宿主按顺序恢复原事件后才分发，拒绝乱序、重复和超过 64 MiB 的合并内容。缺块不会分发部分事件，后续完整事件或新的分块序列可恢复。内容不因帧上限而截断。

## 本地主动助手协议

以下命令要求 `requestId`，回执为 `localModel.operation`，带相同 ID、`operation`、`state`（`started` / `succeeded` / `failed` / `cancelled`）和可选 `message`，不持久化账户回执。

| 命令 | 字段 | 行为 |
| --- | --- | --- |
| `localModelConfigure` | `localModel` | 保存并应用本地配置；不中断手动会话，必要时先取消后台分析。 |
| `localModelModels` | `localModel` | 从表单指定服务读取模型列表，成功回执附 `models`，不保存草稿配置。 |
| `localModelTest` | 无 | 实际请求已保存的本地模型并验证结构化输出。 |
| `localModelCancel` | 原操作的 `requestId` | 取消正在读取目录或测试的操作。 |
| `proactiveConfigure` | `workLookbackHours` | 保存回看范围（`24` / `168` / `720`），成功回执包含已保存值；必要时取消旧后台任务，后续采集使用新范围。 |
| `proactiveCheck` | 无 | 安排本机近期工作上下文检查；主动建议暂停、未配置本地模型或手动任务占用时拒绝。 |

`agent.status.payload.localModel` 包含本地连接状态、无密钥的 `configuration`、`hasAPIKey`、`workLookbackHours` 和机器推荐信息。它独立于手动会话的 `model`。

`context.request` 的 `work` 请求携带 `lookbackHours`。宿主返回 `scope:"local-work-context"`、`lookbackHours`、`items` 和 `coverage`；每个 item 含稳定 `id`、`source`（`application` / `process` / `workspace` / `document` / `browser-history`）、`title`、`observedAt`、`contentStatus` 及可选正文和来源字段。工作回包最多 512000 字符，通知仍为 40000；旧 `work.text` 格式继续兼容。所有内容都是待分析数据，不是模型指令。

`agent.activity` / `agent.usage` 用 `runId` 标识一次模型执行，升级远端产生新的 `runId` 并附 `parentRunId`。模型记录可带 `route`、`provider`、`endpoint`、`requestPath`、`startedAt`、`durationMs`、`upstreamRequestId`、应用信息和实际用量；旧字段缺失时不能按相近时间推算。`reasoningEffort` 不包含思考正文。

电脑工具回执的 `targetAppName`、`targetBundleId`、`targetWindowTitle` 记录实际目标应用与窗口。工具耗时由同一 `toolCallId` 的开始和结束事件计算；缺少配对事件时保持未知。

自动草稿的 `proactive.suggestion` 带 `conversationId`、`state:"completed"` 和真实 `draft` / `text`，同时发出 `conversation.updated`；宿主显示该会话，不再重复创建建议卡片。使用 `conversationRead` 获取完整结果。未产出草稿的建议仍使用原来的 `suggestionId` / `decide` 流程。保持安静、重复、升级、失败等决策写入可查看的活动记录。
