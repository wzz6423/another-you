# Another You Agent Core

Node 22.19+ 的本地优先主动助手运行时，通过 JSON Lines 与 SwiftUI 通信。使用官方 Pi SDK 完成真实模型请求；建议触发、审批状态、冷却和审计记录由 Another You 管理。当前只生成可审阅的草稿，任何模型均无文件、Shell、网络工具或外部消息发送能力。

## 安装与启动

```bash
npm ci --ignore-scripts
npm run check
npm test
npm start -- --config "$HOME/Library/Application Support/AnotherYou/config.json"
```

Node 原生擦除 TypeScript，不需要构建产物。`npm run check` 使用真正的 TypeScript 类型检查。stdout 只输出 JSONL；诊断写入 stderr。若配置文件不存在，采用本机端点和 `local-default` 占位模型；此时 `model.configured=false`，不会向模型发送请求，直到用户在设置中选择已安装模型。

本地配置示例见 `config.example.json`。示例模型 `qwen3:8b` 需要用户自行安装或替换为已有模型；运行时不下载模型。默认端点为 Ollama 的 OpenAI 兼容接口 `http://127.0.0.1:11434/v1`，也可使用本机 LM Studio / llama.cpp 的兼容接口。

## Pi 来源与定制边界

`pi-source.lock.json` 分别记录最新源码提交 `commit` 与官方 SDK 发布提交 `sdkCommit`，两者不混淆：源码用于后续私有化修改，实际运行使用 npm 发布的 `@earendil-works/pi-agent-core` 和 `@earendil-works/pi-ai` **0.99.2**，完整依赖树及完整性摘要固定在 `package-lock.json`。源码与 SDK 许可均为 MIT。

```bash
./scripts/bootstrap-pi.sh fetch
./scripts/bootstrap-pi.sh --check
# HTTPS Git 不可用时，使用已配置的 GitHub SSH：
PI_GIT_TRANSPORT=ssh ./scripts/bootstrap-pi.sh fetch
PI_GIT_TRANSPORT=ssh ./scripts/bootstrap-pi.sh --check
```

源码检出到被忽略的 `.cache/pi`，以 detached HEAD 校验 SHA；不会复制进应用源码。`--refresh` 仅有意更新源码锁，运行时 SDK 版本需另外审阅更新。源码仓库为 <https://github.com/earendil-works/pi>，旧 `badlogic/pi-mono` 已重定向。

`src/pi-adapter.ts` 显式创建 Pi `Agent`，使用空工具列表、独立单次会话与受限 HTTP fetch。不会运行 Pi coding CLI，不读取用户 Pi 配置、skills、扩展或默认工具，也不启用遥测导出器。上游 SDK 的状态与工具循环可以继续在这个窄接口后定制。

## 模型与隐私

`model.provider` 支持 `local`、`openai-compatible`、`anthropic`。模型名称与端点必须由用户提供；外部模型的密钥仅接受 `model.apiKeyEnv` 指向进程环境变量，配置中拒绝 `apiKey` / `api_key`。不会自动使用 Pi 用户登录态或其他默认环境密钥。

- `local` 仅接受回环地址，`localhost` 会固定到 `127.0.0.1`。
- `strict-local` 禁止外部主机。外部模型必须同时设定 `privacy.mode` 为 `local-first` 或 `custom`、`allowNetwork=true`、精确匹配的 `allowedNetworkHosts`，并使用 HTTPS。
- 每次模型 fetch 都复查目标来源，拒绝 HTTP 重定向，避免把内容或凭据带到另一目标。
- 请求最多运行 60 秒，不隐式重试。当前模型请求进行时，新模型请求立即返回 busy 错误；暂停、状态查询和关闭仍能处理。
- `model.configured` 仅表示配置完整有效；`model.available=null` 表示未实际验证，真实请求成功后为 `true`，失败后为 `false`。主动规则触发不代表模型可用。

`dataDir/state.json` 采用原子替换和 `0600` 权限，存储建议处理状态、规则、冷却/去重摘要，以及最多 200 条事件、100 条已完成/忽略建议。尚未处理的建议保留。退出时进行中的生成在重启后标为失败，不会自动重试。状态文件损坏时明确报错，不静默丢弃记录。

`storePrompts=false` 时，磁盘历史省略 prompt/context/signal，建议和规则的 context 也不保存；`storeResponses=false` 时省略历史和建议中的 text。关闭字段保存后仍保留时间、ID、建议状态等审计元数据；任一内容保存开关关闭时，错误详情不落盘，避免服务端在错误中回显私人输入。去重键只保存 SHA-256 摘要。`redactSecrets=true` 会清理常见 token、API key、Bearer 凭据模式及同名嵌套字段；它不是任意私密文本识别器。上述设置只控制本地持久化，模型请求本身仍包含用户明确提交的内容。

## Swift JSON Lines 协议

启动参数：

```bash
node --experimental-strip-types /absolute/path/agent-core/src/cli.ts --stdio --config /absolute/path/config.json
```

每行输入一个 JSON 对象，输出统一为 `{id,occurredAt,kind,source,payload}`。`occurredAt` 为 ISO 时间。核心启动会恢复状态、启动调度器、触发 `app-launched`，并输出 `agent.status`。默认规则包括应用启动、当地时间 09:00、宿主报告闲置 15 分钟。未连接任何日历、邮件或活动读取服务，不虚构个人活动。

| 输入命令 | 结果 |
| --- | --- |
| `{ "op":"prompt", "requestId":"unique-id", "prompt":"..." }` | `agent.request`，然后 `agent.response {requestId,text,model}` 或 `agent.error {requestId,message}` |
| `{ "op":"decide", "suggestionId":"...", "decision":"execute" }` | `proposal.updated {suggestionId,decision,state:"running"}`，随后 `completed` 加 `text`，或 `failed` 加错误 `text` |
| `{ "op":"decide", "suggestionId":"...", "decision":"later", "snoozeMinutes":15 }` | `proposal.updated`，`state:"snoozed"`、`snoozedUntil`；默认 15 分钟，允许 1–1440 分钟 |
| `{ "op":"decide", "suggestionId":"...", "decision":"ignore" }` | `proposal.updated`，`state:"ignored"` |
| `{ "op":"pause" }` / `{ "op":"resume" }` | 暂停/恢复主动调度，输出 `scheduler.status` 与 `agent.status`；已提交的聊天生成继续 |
| `{ "op":"status" }` | `agent.status`，包含 `paused,schedulerEnabled,model,rules,proposals,history,configPath` |
| `{ "op":"signal", "signal":{"type":"event","name":"focus-ended","payload":{}} }` | 匹配事件规则后输出 `proactive.suggestion` |
| `{ "op":"tick", "now":"2026-10-01T09:00:00+08:00", "idleForMs":0 }` | 时间/闲置规则与到期延后建议；实际闲置时长由 macOS 宿主提供 |
| `{ "op":"addRule", "rule":{...} }` / `{ "op":"removeRule", "ruleId":"..." }` | 保存规则变更 |
| `{ "op":"shutdown" }` | 停止调度、取消模型请求、等待状态保存后退出 |

`proactive.suggestion.payload` 包含 `suggestionId,ruleId,title,message,summary,reason,createdAt,state,trigger,context,signal`。**建议身份始终使用 `payload.suggestionId`**；延后恢复会产生新事件 ID，但建议 ID 保持相同。

`proposals` 中每项包含 `id,ruleId,title,summary,reason,createdAt,state,context`，可选 `text,snoozedUntil`。状态集合为 `pending | running | completed | snoozed | ignored | failed`。已完成、已忽略、正在执行的建议拒绝重复处理。失败可经用户再次批准重试。模型请求完成或失败后自动更新 `agent.status`。

## 验证范围

测试用本机 HTTP 服务驱动官方 Pi SDK，覆盖无工具模型请求、外网与重定向拒绝、HTTP 失败、隐私不落盘、凭据脱敏、延后与重启恢复、重复批准拒绝和 JSONL 子进程。慢模型期间的暂停、查询、并发拒绝、关闭均单独验证。测试不需要真实 API 密钥或下载模型，临时数据在结束后清理。
