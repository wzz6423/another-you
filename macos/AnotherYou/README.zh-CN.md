# Another You macOS 客户端

[English](README.md) | **简体中文**

0.1.0 开发预览的原生 SwiftUI 客户端，提供主窗口、菜单栏控制、Pi 模型状态与可选系统通知。目前 UI 使用中文。Agent 规则、模型请求与建议状态持久化由 Node sidecar 负责。

## 从源码运行

应用支持 macOS 14+；从源码构建需要完整 Xcode 27+、macOS 27+ SDK、Node.js 22.19+ 和 npm。从仓库根目录执行：

```bash
make deps
make run
```

`make run` 构建并启动 `dist/dev/Another You.app`，进程记录和日志放在同一目录；启动诊断见 `dist/dev/another-you.log`。

```bash
make stop
make update
```

`make stop` 停止本工作区管理的开发实例。`make update` 按本地源码重建并重启，不拉取 Git 更新。独立开发应用和内置 Node 的说明见 [打包文档](../../docs/releasing.zh-CN.md)。

不使用应用包、直接进行 Swift 开发时：

```bash
ANOTHER_YOU_AGENT_ROOT="$PWD/agent-core" \
  ./scripts/xcode-toolchain.sh run --package-path macos/AnotherYou AnotherYou
```

直接运行可使用主界面和 sidecar，但系统通知需要 `.app` 应用包。可从菜单栏退出应用；前台源码运行也可用 `Ctrl+C` 结束。

构建和测试使用 `DEVELOPER_DIR` 或 `xcode-select` 选定的完整 Xcode；仅有 Command Line Tools 或 Xcode 低于 27 时会拒绝执行。`make build SWIFT_SCRATCH_PATH=/tmp/another-you-swift` 和 `make test-swift SWIFT_SCRATCH_PATH=/tmp/another-you-swift` 可将验证产物与默认 `.build` 隔离，验证后单独清理该临时目录。

## 使用 Pi 模型

设置按通用、模型、主动建议、电脑操作、快捷键、软件更新分页。模型页只读展示 Pi 当前默认模型、提供方和思考深度；不保存另一份模型或认证配置。

1. 在本机 Pi 中完成认证（`/login`）或配置模型服务。本地模型同样通过 Pi 的 `models.json` 或本地模型功能配置。
2. 在 Pi 的 `/model` 中选择模型并按 **Ctrl+S** 保存为默认；需要时在 `/thinking` 中保存默认思考深度。
3. 在 Another You 的 **设置 → 模型** 点击 **重新读取 Pi 配置**，然后发送请求验证模型。

应用读取 Pi 的 `settings.json`、`models.json` 和 `auth.json`，默认目录为 `~/.pi/agent`，遵循 `PI_CODING_AGENT_DIR`。旧 Another You 配置中的 `model` 不再生效，也不会自动写入 Pi。缺少默认模型或认证时明确提示；读取成功不等于模型请求已验证。模型请求仍通过 Pi 的原生认证与提供方适配执行。

## 会话与用量

快速会话显示玻璃胶囊输入框；有截图时在上方显示可移除的附件预览，位于鼠标所在屏幕水平中央、距屏幕底部 20% 处。macOS 26+ 使用原生液态玻璃，旧系统回退磨砂材质；Return 或发送快捷键提交后收起，回复在主界面会话中查看。

侧边栏的 **会话** 打开独立会话页。应用运行时，**⌘⇧Space** 在其他应用中也能呼出快速会话框；**⌘Return** 发送，**Esc** 隐藏小窗口。两个入口共享已发送消息，关闭小窗口不会清空会话。快捷键注册失败时可使用菜单的快速会话入口。每个会话最近 20 轮成功对话作为自身的后续请求上下文，不混入其他会话或建议草稿。会话标题、状态与完整消息历史由 sidecar 持久化，重启恢复遵循内容保存偏好；截图二进制不持久化，也不会在后续轮次假装重传。

首页与 **会话** 页面以 **进行中 / 已完成** 两列展示会话和主动建议，可按快照关联的应用分组。会话页的 **已归档会话** 默认折叠，可展开后查看、恢复或删除。看板下方的新会话输入框与看板分隔，首次发送后才创建会话；切换时保留各自未发送的文字和快照附件。点击会话进入详情，查看完整上下文、继续讨论、导出，或从某一轮／整个会话创建独立分支。归档详情可直接恢复后继续；分支保留来源，不修改原会话或重复计入用量。点击建议可查看并决定下一步。执行中的会话需先停止，所有操作以 sidecar 回执为准。会话 Markdown 与首页用量 CSV 的内容和限制见 [导出说明](../../docs/exporting.zh-CN.md)。

**活动记录** 按条显示思考、执行、运行命令和读取应用上下文的阶段，可按类型筛选或分组；思考日志只记录开始/结束状态，不保存模型的思考正文。

首页饼图显示模型 Token 占比，支持 **24h / 7d / 15d / 30d**，并列出输入、输出、缓存、模型排行、思考深度和工具调用。统计从本版本开始，保留 30 天；失败请求已报告的用量也会计入。服务未报告用量时显示未报告，不估算。Plugin / Skill / MCP 仅在运行时确有对应调用记录时显示，当前没有内置这些连接器。

## 建议与通知

建议来自应用启动、本地时间和 Mac 的真实闲置信号。闲置采样每 30 秒运行一次。截图与应用上下文通过会话入口及具备系统权限的采集功能获取。规则冷却与尚未处理的建议共同限制重复打扰。

建议支持 **生成草稿**、**稍后** 和 **忽略**。稍后默认延迟 15 分钟；到期时，运行时需保持运行，主动调度已启用且未暂停，建议才会恢复。生成状态以 sidecar 的回执为准，失败可由用户手工重试。**暂停主动建议** 跨重启保存，不取消已经提交的模型请求。

系统通知初始关闭。在打包后的应用中，开启 **设置 → 介入方式 → 新建议显示系统通知** 并允许 macOS 通知权限。应用非活跃且主动建议未暂停时，新建议事件可请求系统通知；仅加载已保存卡片不会通知。macOS 设置与专注模式可能影响送达，开启选项不代表通知已成功送达。

通知偏好单独存于 `UserDefaults` 的 `notificationsEnabled`，与 `config.json` 和 `tools.notifications` 分开；修改该 Agent 字段不会开关原生通知。应用必须运行才能观察信号，目前没有登录时启动或应用关闭后的调度。

## 运行路径与排障

| 现象 | 检查项 |
| --- | --- |
| 未找到 Agent | 从仓库根目录运行，或将 `ANOTHER_YOU_AGENT_ROOT` 指向 `agent-core` 的绝对路径；应用包通常从资源目录加载。 |
| Node 缺失或提前退出 | 确认 Node 22.19+，运行 `make deps`；必要时用 `ANOTHER_YOU_NODE` 指定可执行文件的绝对路径。 |
| Agent 12 秒内未响应 | 查看界面启动错误与开发日志，检查 Node、依赖，以及配置/状态是否损坏。 |
| 模型未配置或请求失败 | 核对模型名称、服务状态、端点兼容性和运行状态中的错误信息。 |
| 无法使用通知 | 使用应用包，检查主动开启、macOS 权限、应用非活跃状态，以及冷却后是否有新建议可触发。 |
| 没有新建议 | 检查暂停/配置、本地时间、冷却和未处理卡片；欢迎规则最多每 24 小时触发一次。 |

配置和状态通常位于 `~/Library/Application Support/AnotherYou/`。`ANOTHER_YOU_DATA_DIR` 可为 Swift 宿主指定其他目录；隔离开发数据时使用仓库外的绝对路径。该变量不会隔离单独存储的 `UserDefaults` 通知偏好。文件行为和存储限制见 [配置参考](../../docs/configuration.zh-CN.md)。

## 验证与清理

从仓库根目录执行：

```bash
make deps
make test-swift
make clean
```

[AnotherYouCoreTests.swift](Tests/AnotherYouTests/AnotherYouCoreTests.swift) 覆盖 JSONL 分帧、设置、运行时查找、基于回执的 UI 状态、进程恢复和真实 Node sidecar 往返。Sidecar 测试需要 npm 依赖，不需要真实模型。变更后的窗口/菜单交互、真实模型请求和通知仍需单独手工验证。

`make clean` 停止受管理的开发应用并清理已知构建和测试产物，保留个人应用数据、依赖、Pi 源码缓存与自定义打包目录。

## 代码与相关文档

[AgentClient.swift](Sources/AnotherYouCore/AgentClient.swift) 负责进程与协议；[AssistantStore.swift](Sources/AnotherYouCore/AssistantStore.swift) 将事件转换成 UI 状态并采样闲置时长；[AgentSettings.swift](Sources/AnotherYouCore/AgentSettings.swift) 负责本地设置持久化。[MainWindowView.swift](Sources/AnotherYouCore/MainWindowView.swift) 包含视图，[main.swift](Sources/AnotherYou/main.swift) 创建窗口、设置场景和菜单栏。

修改 Swift/Node 边界前，请阅读 [架构](../../docs/architecture.zh-CN.md)、[CLI 与 JSONL 协议](../../docs/cli-reference.zh-CN.md) 和 [贡献指南](../../CONTRIBUTING.zh-CN.md)。

## 快捷键、截图与后台操作

[快捷键、截图与后台操作](../../docs/desktop-automation.zh-CN.md)说明所有快捷键的重录、截图预览、系统权限和操作范围。
