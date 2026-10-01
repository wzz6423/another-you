# Another You macOS 客户端

[English](README.md) | **简体中文**

0.1.0 开发预览的原生 SwiftUI 客户端，提供主窗口、菜单栏控制、本地模型设置与可选系统通知。目前 UI 使用中文。Agent 规则、模型请求与建议状态持久化由 Node sidecar 负责。

## 从源码运行

需要 macOS 14+、Swift 6、Node.js 22.19+ 和 npm。从仓库根目录执行：

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
  swift run --package-path macos/AnotherYou AnotherYou
```

直接运行可使用主界面和 sidecar，但系统通知需要 `.app` 应用包。可从菜单栏退出应用；前台源码运行也可用 `Ctrl+C` 结束。

## 连接模型

1. 单独启动兼容的本机模型服务，确认它实际提供的模型名称。Ollama 可使用 `ollama list` 查看已安装模型。
2. 打开 **设置 → 本地模型**，填写服务地址与模型名称。Ollama 常用地址为 `http://127.0.0.1:11434/v1`。
3. 选择 **保存并重新连接**，然后提交一条提问或从建议生成草稿，验证连接。

应用不会安装模型或启动模型服务。保存设置只校验并写入配置，实际模型请求成功才代表可用性验证。设置 UI 仅接受 `localhost`、`127.0.0.1` 和 `::1` 回环地址。

保存时会把模型段替换为 `provider=local`、`temperature=0.2`，将隐私模式设为 `strict-local`，清空远程主机授权，并关闭 `tools.network`；内容保存偏好会保留。远程模型需要手工配置，并确保进程环境含有所指定的密钥，详见 [配置参考](../../docs/configuration.zh-CN.md)。之后通过本地模型 UI 保存，会覆盖该远程配置。

## 建议与通知

建议来自应用启动、本地时间和 Mac 的真实闲置信号。客户端每 30 秒采样闲置时长，不读取屏幕、消息、日历或当前工作。规则冷却与尚未处理的建议共同限制重复打扰。

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
