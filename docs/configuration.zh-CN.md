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

## 应用配置与 Pi 模型

`version` 为 `1`，`dataDir` 是应用状态目录，`permissionMode` 固定为 `full-access`。旧 JSON 中的 `model` 字段不再参与运行时模型选择。

模型、端点、认证、模型能力和思考深度统一从 Pi 原生配置读取：

| Pi 文件 | 用途 |
| --- | --- |
| `settings.json` | `defaultProvider`、`defaultModel`、默认及每模型思考深度。 |
| `models.json` | 自定义提供方、本地模型、端点、兼容参数与模型覆盖项。 |
| `auth.json` | Pi 管理的认证，包括 API key 与 OAuth。 |

应用使用独立的 `<dataDir>/pi`，不读取 `~/.pi/agent`、`PI_CODING_AGENT_DIR` 或宿主环境中的提供方密钥。设置页展示 Pi SDK 内置与缓存的全部聊天模型，可按模型或提供方搜索，并保存默认模型和每模型思考深度。没有默认模型时不会自行挑选其他提供方。

账户页采用 Pi SDK 提供的 API key / OAuth 登录方式，支持网页、设备码和手动授权码交互及取消。凭据只写入独立的 `auth.json`；目录权限为 `0700`，配置与认证文件为 `0600`。认证提示和回执只通过即时协议发送，不进入会话或状态历史。应用不执行认证命令，也不解析环境变量凭据；发现此类引用时会标记待配置，需在应用内配置账户并移除外部引用。

“导入 Pi 配置…”接受 `models.json` 或包含该文件的目录，并读取同目录中可选的 `settings.json`。导入模型定义与有效默认选择，移除 API key、headers 和认证环境字段，不复制源 `auth.json`，不覆盖当前账户。现有个人 Pi 配置保持原样。

本地 Ollama 示例应写入 **Pi 的 models.json**：

```json
{"providers":{"ollama":{"baseUrl":"http://localhost:11434/v1","api":"openai-completions","apiKey":"ollama","models":[{"id":"qwen3:8b"}]}}}
```

保存自定义模型后，点击模型页“重新读取配置”，然后选中模型并点击“使用此模型”。启动和重新读取只恢复本地配置与目录缓存；“更新模型目录”显式请求已配置提供方的 SDK 目录刷新，部分失败时仍展示已更新部分。正在执行的模型请求或账户操作期间不能更改模型配置。`model.configured` 表示凭据已配置，`model.available` 表示最近请求结果；保存配置和更新目录不证明模型请求可用，也不发送测试提示词。

## 隐私与网络字段

| 字段 | 类型 / 默认值 | 含义 |
| --- | --- | --- |
| `privacy.mode` | 字符串，`local-first` | 兼容读取旧值，运行时统一为 `local-first`。 |
| `privacy.allowNetwork` | 布尔，`true` | 完全权限模式统一启用。 |
| `privacy.allowedNetworkHosts` | 字符串数组，`[]` | 兼容旧配置；完全权限模式不使用主机白名单。 |
| `privacy.storePrompts` | 布尔，`true` | 在持久化状态中保留 prompt/context/signal 内容。 |
| `privacy.storeResponses` | 布尔，`true` | 在持久化状态中保留回复文本。 |
| `privacy.redactSecrets` | 布尔，`true` | 保存状态时进行基础凭据模式遮盖。 |

模型请求遵循 Pi 的提供方配置、认证和协议实现；应用不再维护另一套模型地址校验。内容保存开关仅控制 Another You 状态持久化。

## 工具声明与原生通知

| 字段 | 默认值 |
| --- | --- |
| `tools.filesystem` | `true` |
| `tools.shell` | `true` |
| `tools.network` | `true` |
| `tools.calendar` | `false` |
| `tools.notifications` | `true` |

运行时提供文件读写、目录列表、Shell 和 HTTP 网络工具，直接执行用户请求。前三项始终启用，旧限制会迁移；`calendar` 仍只是兼容声明，没有内置日历连接器。操作系统权限仍由 macOS 管理。

原生通知由 `AssistantStore`、独立的 `UserDefaults` 偏好与 macOS 权限控制，`tools.notifications` 不会开启或关闭它。需要应用包、用户主动开启、应用非活跃，以及未暂停时的新建议事件；最终送达仍取决于 macOS。详见 [macOS 指南](../macos/AnotherYou/README.zh-CN.md)。

## 调度字段

| 字段 | 类型 / 默认值 | 含义 |
| --- | --- | --- |
| `scheduler.enabled` | 布尔，`true` | 启用主动信号处理；禁用后仍可显式请求模型。 |
| `scheduler.pollIntervalMs` | 数字，`30000` | 核心 tick 间隔，至少 100 ms。 |
| `scheduler.defaultCooldownMs` | 数字，`1800000` | 规则默认冷却，30 分钟。 |
| `scheduler.defaultDedupeWindowMs` | 数字，`300000` | 默认去重窗口，5 分钟。 |

时长必须为有限非负数，配置值向下取整为整数毫秒。单条规则可覆盖冷却和去重窗口，内置规则有各自冷却值。规则定义与示例见 [CLI 参考](cli-reference.zh-CN.md)。Swift 闲置采样有独立的固定 30 秒间隔，修改 `pollIntervalMs` 不会改变该采样频率。

## 主动工作分析字段

| 字段 | 默认值 | 含义 |
| --- | ---: | --- |
| `proactive.enabled` | `true` | 启用后台采集与分析；暂停主动建议时也会停止未完成采集。 |
| `proactive.workIntervalMs` | `300000` | 工作窗口检查间隔，5 分钟。 |
| `proactive.notificationsIntervalMs` | `180000` | 可访问通知内容检查间隔，3 分钟。 |
| `proactive.synthesisIntervalMs` | `600000` | 父 agent 汇总间隔，10 分钟。 |
| `proactive.suggestionCooldownMs` | `900000` | 主动建议最短间隔，15 分钟。 |
| `proactive.taskSpacingMs` | `30000` | 不同后台任务之间的最短间隔，30 秒。 |
| `proactive.collectionTimeoutMs` | `15000` | Swift 采集回执超时。 |
| `proactive.taskTimeoutMs` | `90000` | 子 agent 或父 agent 任务总超时。 |

工作和通知任务分别执行；内容指纹、通知摘要和建议冷却跨重启保存。没有新变化时跳过模型调用，失败会指数退避。子 agent 只分析并返回结构化事实，父 agent 决定是否生成一条建议；后台 agent 不提供文件、Shell、网络或桌面执行工具。macOS 采集只读取辅助功能允许访问的当前窗口和通知中心可见文本，不截图、不扫描通知数据库、不读取磁盘文件；辅助功能权限不足、会话锁定或通知已消失时会返回明确状态。

## 状态保留内容

状态包含规则、暂停、建议状态、冷却时间戳、去重摘要、按事件时间保留最近 30 天且不按条数截断的历史事件、独立保留最近 30 天的 `usageRecords`（token、模型、思考深度、工具调用与结果），以及合计最多 100 条已完成/已忽略建议。无效的历史时间戳会丢弃；未来事件暂存，但到达该时间前不出现在活动页，与用量筛选一致。旧版本已截断的记录无法恢复。待处理、执行中、稍后和失败建议继续保留。状态事件不加入历史。重启时未完成的执行中建议变为失败，不自动重试。

- `storePrompts=false` 会从持久化历史中移除 `prompt`、`context` 和 `signal`，清空建议上下文，并移除规则上下文。规则标题/说明和建议标题/摘要仍会保留，它不能清除所有用户文本。
- `storeResponses=false` 会移除历史与建议中的 `text` 字段。
- 任一内容保存开关关闭时，持久化的 `agent.error` 详情替换为通用信息。关闭提示词保存也会移除失败建议文本；关闭回复保存则移除全部建议文本。
- `redactSecrets=true` 遮盖常见 `sk-`、GitHub token、Bearer、API key、password、secret 和 token 模式，包括能识别的嵌套字段名；无法识别任意私人文本。

这些控制作用于待保存副本，不过滤实时 JSONL 或内存状态，也不会在下一次保存前改写已有文件。去重键保存为 SHA-256 摘要。状态通过临时文件和原子重命名写入，权限为 `0600`；新建状态目录请求 `0700` 权限。Swift 也使用原子写入和 `0600` 权限保存配置。应用不会加密这两个文件。损坏状态会报错，应保留文件供修复，不要假定它已自动重置。

## 环境与构建覆盖项

| 名称 | 使用方 / 作用 |
| --- | --- |
| `ANOTHER_YOU_DATA_DIR` | Swift 宿主：选择 `config.json` 所在目录；新建应用配置时把 `dataDir` 设为该目录。独立 Node CLI 不读取此变量，应使用 `--config` 与 `dataDir`。 |
| `ANOTHER_YOU_AGENT_ROOT` | Swift 宿主：显式指定 `agent-core` 的绝对路径，优先于应用包/开发路径查找。 |
| `ANOTHER_YOU_NODE` | Swift 宿主与打包：显式指定 Node 可执行文件，不决定安装依赖时使用的 `npm`。 |
| `OUTPUT_DIRECTORY` | 打包：输出目录，默认 `dist/macos`；`make run`/`make update` 使用固定 `dist/dev`。 |
| `BUNDLE_NODE` | 打包：`0` 使用本机 Node，`1` 复制兼容的自包含 Node，默认 `0`。 |
| `APP_VERSION` / `APP_BUILD` | 打包：版本与构建号，默认 `0.1.0` / `1`。 |
| `BUILD_ARCH` | 打包：`arm64` 或 `x86_64`，默认本机架构。 |
| `ANOTHER_YOU_NODE_LICENSE` | 打包：显式 Node 许可证路径，内置 Node 时必须提供相邻许可证或此路径。 |
| `PORT` | `make website`：回环预览端口，默认 `4173`。 |
| `PI_GIT_TRANSPORT` | 源码引导：`ssh` 使用已配置的 GitHub SSH 传输，默认 HTTPS。 |
| `PI_SOURCE_DIR` | 源码引导：覆盖默认 `agent-core/.cache/pi`。 |
| `PI_SOURCE_LOCK` | 源码引导：覆盖默认 `agent-core/pi-source.lock.json`。 |

运行时覆盖项使用绝对路径。显式指定的 Agent 或 Node 路径不存在时会报错，不继续回退。Swift 通常先找应用资源，再找开发目录或系统 Node。`ANOTHER_YOU_DATA_DIR` 不会移动 `UserDefaults` 通知偏好。相关命令见 [打包](releasing.zh-CN.md) 与 [来源](sources.zh-CN.md)。

应用更新偏好由 `UserDefaults` 的 `SUEnableAutomaticChecks`、`SUAutomaticallyUpdate` 和 `AnotherYouAutomaticallyInstallsUpdates` 保存，与 Agent 配置分开。三项初始关闭；更新源、公钥与正式发布变量见[发布指南](releasing.zh-CN.md)。
