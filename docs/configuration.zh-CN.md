# 配置参考

[English](configuration.md) | **简体中文**

配置为 JSON，由 [config.ts](../agent-core/src/config.ts) 校验。省略字段采用下方默认值；JSON 损坏或配置结构/类型校验失败会阻止启动。可参考 [config.example.json](../agent-core/config.example.json)，将示例模型替换为服务实际提供的名称。

## 文件与加载

| 项目 | macOS 默认位置 |
| --- | --- |
| 配置 | `~/Library/Application Support/AnotherYou/config.json` |
| 运行时状态 | `<dataDir>/state.json` |
| 原生通知偏好 | `UserDefaults` 的 `notificationsEnabled`，初始为 `false` |

Swift 宿主会创建缺失的配置，并把路径传给 sidecar。CLI 支持 `--config /absolute/path/config.json`；文件不存在时采用默认值，并以文件所在目录作为 `dataDir`，但不写入配置文件。启动核心仍可能写入 `state.json`。

已有 JSON 的 `dataDir` 独立控制状态位置；省略时使用平台默认数据目录。只通过 `--config` 移动已有配置，不代表状态也被隔离。`dataDir` 中的 `~` 会展开，其他相对路径以 sidecar 工作目录解析。建议使用仓库外的绝对路径。

产品仅支持 macOS。独立核心还定义了 Windows（`%APPDATA%/AnotherYou`）及其他系统（`$XDG_DATA_HOME/another-you`，未设置时为 `~/.local/share/another-you`）的默认数据目录，但不代表这些平台已有原生客户端。

## 通用与模型字段

| 字段 | 类型 / 默认值 | 含义 |
| --- | --- | --- |
| `version` | 数字，`1` | 仅支持配置版本 1。 |
| `dataDir` | 字符串，平台默认数据目录 | 存放运行时状态的目录。 |
| `model.provider` | 字符串，`local` | 可选 `local`、`openai-compatible` 或 `anthropic`。 |
| `model.model` | 字符串，`local-default` | 服务实际提供的模型名称；默认值是占位符，不能用于请求。 |
| `model.endpoint` | 字符串，`local` 默认 `http://127.0.0.1:11434/v1` | HTTP(S) 基础地址；其他提供方必须显式配置。 |
| `model.apiKeyEnv` | 可选字符串，未设置 | 保存密钥的环境变量名，不是密钥本身。 |
| `model.temperature` | 数字，`0.2` | 0 到 2 之间的有限值。 |

`local` 和 `openai-compatible` 使用 Pi 的 OpenAI Chat Completions 调用，`anthropic` 使用 Messages 调用。地址不能包含凭据、查询参数或片段。`localhost` 会归一化到 `127.0.0.1`；非 Anthropic 提供方的根路径会变为 `/v1`。基础地址应与服务实际 API 对应。

`local` 后端只接受回环主机（`localhost`、`127.*` 或 `::1`）。Swift 设置界面更窄，仅支持 `localhost`、`127.0.0.1` 或 `::1`。本机请求未设 `apiKeyEnv` 时使用固定的非机密占位密钥；显式设置后，该变量必须有值。其他两个提供方即使使用回环端点，也必须指定密钥变量名。配置中的 `apiKey`、`api_key` 会被拒绝；不会自动加载 Pi 登录态或默认提供方密钥变量。

状态中的 `model.configured` 表示模型名称、端点策略和密钥引用有效。`model.available` 在请求前为 `null`，成功后为 `true`，失败后为 `false`；无效配置也会报告 `false`。该状态仅对应当前 sidecar 运行。规则建议和设置保存成功都不代表验证了模型可用性。

## 隐私与网络字段

| 字段 | 类型 / 默认值 | 含义 |
| --- | --- | --- |
| `privacy.mode` | 字符串，`strict-local` | 可选 `strict-local`、`local-first` 或 `custom`；后两者目前使用相同的显式远程主机检查。 |
| `privacy.allowNetwork` | 布尔，`false` | 仅在满足下方其他检查时允许非回环模型请求；`strict-local` 强制将其设为 `false`。 |
| `privacy.allowedNetworkHosts` | 字符串数组，`[]` | 精确主机名，去除两端空格并转小写；不含协议、端口或路径，不支持通配符匹配。 |
| `privacy.storePrompts` | 布尔，`true` | 在持久化状态中保留 prompt/context/signal 内容。 |
| `privacy.storeResponses` | 布尔，`true` | 在持久化状态中保留回复文本。 |
| `privacy.redactSecrets` | 布尔，`true` | 保存状态时进行基础凭据模式遮盖。 |

非回环端点必须同时满足：提供方不是 `local`、模式为 `local-first` 或 `custom`、`allowNetwork=true`、主机精确出现在 `allowedNetworkHosts` 中，以及 HTTPS。每次 fetch 都重新校验目标、要求保持配置来源并拒绝 HTTP 重定向。此策略不控制依赖下载、Git 命令或其他进程。

有意授权远程 OpenAI 兼容服务时，可使用以下结构。`api.example.com` 与 `REPLACE_WITH_MODEL` 是占位值，不是可用服务：

```json
{
  "version": 1,
  "model": {
    "provider": "openai-compatible",
    "model": "REPLACE_WITH_MODEL",
    "endpoint": "https://api.example.com/v1",
    "apiKeyEnv": "ANOTHER_YOU_MODEL_KEY",
    "temperature": 0.2
  },
  "privacy": {
    "mode": "local-first",
    "allowNetwork": true,
    "allowedNetworkHosts": ["api.example.com"],
    "storePrompts": false,
    "storeResponses": false,
    "redactSecrets": true
  }
}
```

密钥需通过指定名称注入实际 sidecar 进程环境，不要提交到仓库。从 Finder 启动的应用不一定继承终端 export。请求会将提交的提示词，以及建议的显式上下文发送给所选服务；内容保存开关不会移除实时请求中的内容。

Swift 本地模型设置保存时，会将模型段替换为 `local` 与温度 `0.2`，移除密钥引用，将隐私模式重置为 `strict-local`，关闭网络授权、清空允许主机，并设置 `tools.network=false`。内容保存偏好会保留。不要期望手工填写的远程模型配置在通过此 UI 保存后仍保持不变。

## 工具声明与原生通知

| 字段 | 默认值 |
| --- | --- |
| `tools.filesystem` | `false` |
| `tools.shell` | `false` |
| `tools.network` | `false` |
| `tools.calendar` | `false` |
| `tools.notifications` | `true` |

工具字段均为布尔值，只声明策略；当前 Pi 适配器始终使用空工具集。设为 `true` 不会增加连接器或可执行模型工具。`tools.network` 也不是模型 HTTP 请求的开关，模型连接遵循上面的模型与隐私规则。

原生通知由 `AssistantStore`、独立的 `UserDefaults` 偏好与 macOS 权限控制，`tools.notifications` 不会开启或关闭它。需要应用包、用户主动开启、应用非活跃，以及未暂停时的新建议事件；最终送达仍取决于 macOS。详见 [macOS 指南](../macos/AnotherYou/README.zh-CN.md)。

## 调度字段

| 字段 | 类型 / 默认值 | 含义 |
| --- | --- | --- |
| `scheduler.enabled` | 布尔，`true` | 启用主动信号处理；禁用后仍可显式请求模型。 |
| `scheduler.pollIntervalMs` | 数字，`30000` | 核心 tick 间隔，至少 100 ms。 |
| `scheduler.defaultCooldownMs` | 数字，`1800000` | 规则默认冷却，30 分钟。 |
| `scheduler.defaultDedupeWindowMs` | 数字，`300000` | 默认去重窗口，5 分钟。 |

时长必须为有限非负数，配置值向下取整为整数毫秒。单条规则可覆盖冷却和去重窗口，内置规则有各自冷却值。规则定义与示例见 [CLI 参考](cli-reference.zh-CN.md)。Swift 闲置采样有独立的固定 30 秒间隔，修改 `pollIntervalMs` 不会改变该采样频率。

## 状态保留内容

状态包含规则、暂停、建议状态、冷却时间戳、去重摘要、最多 200 条历史事件，以及合计最多 100 条已完成/已忽略建议。待处理、执行中、稍后和失败建议继续保留。状态事件不加入历史。重启时未完成的执行中建议变为失败，不自动重试。

- `storePrompts=false` 会从持久化历史中移除 `prompt`、`context` 和 `signal`，清空建议上下文，并移除规则上下文。规则标题/说明和建议标题/摘要仍会保留，它不能清除所有用户文本。
- `storeResponses=false` 会移除历史与建议中的 `text` 字段。
- 任一内容保存开关关闭时，持久化的 `agent.error` 详情替换为通用信息。关闭提示词保存也会移除失败建议文本；关闭回复保存则移除全部建议文本。
- `redactSecrets=true` 遮盖常见 `sk-`、GitHub token、Bearer、API key、password、secret 和 token 模式，包括能识别的嵌套字段名；无法识别任意私人文本。

这些控制作用于待保存副本，不过滤实时 JSONL 或内存状态，也不会在下一次保存前改写已有文件。去重键保存为 SHA-256 摘要。状态通过临时文件和原子重命名写入，权限为 `0600`；新建状态目录请求 `0700` 权限。Swift 也使用原子写入和 `0600` 权限保存配置。应用不会加密这两个文件。损坏状态会报错，应保留文件供修复，不要假定它已自动重置。

## 环境与构建覆盖项

| 名称 | 使用方 / 作用 |
| --- | --- |
| `ANOTHER_YOU_DATA_DIR` | Swift 宿主：选择 `config.json` 所在目录；保存本地模型设置时还会把 `dataDir` 设为该目录。独立 Node CLI 不读取此变量，应使用 `--config` 与 `dataDir`。 |
| `ANOTHER_YOU_AGENT_ROOT` | Swift 宿主：显式指定 `agent-core` 的绝对路径，优先于应用包/开发路径查找。 |
| `ANOTHER_YOU_NODE` | Swift 宿主与打包：显式指定 Node 可执行文件，不决定安装依赖时使用的 `npm`。 |
| `OUTPUT_DIRECTORY` | 打包：输出目录，默认 `dist/macos`；`make run`/`make update` 使用固定 `dist/dev`。 |
| `BUNDLE_NODE` | 打包：`0` 使用本机 Node，`1` 复制兼容的自包含 Node，默认 `0`。 |
| `PORT` | `make website`：回环预览端口，默认 `4173`。 |
| `PI_GIT_TRANSPORT` | 源码引导：`ssh` 使用已配置的 GitHub SSH 传输，默认 HTTPS。 |
| `PI_SOURCE_DIR` | 源码引导：覆盖默认 `agent-core/.cache/pi`。 |
| `PI_SOURCE_LOCK` | 源码引导：覆盖默认 `agent-core/pi-source.lock.json`。 |

运行时覆盖项使用绝对路径。显式指定的 Agent 或 Node 路径不存在时会报错，不继续回退。Swift 通常先找应用资源，再找开发目录或系统 Node。`ANOTHER_YOU_DATA_DIR` 不会移动 `UserDefaults` 通知偏好。相关命令见 [打包](releasing.zh-CN.md) 与 [来源](sources.zh-CN.md)。
