# Another You macOS 客户端

[English](README.md) | **简体中文**

0.1.0 开发预览的原生 SwiftUI 客户端，提供主窗口、菜单栏控制、Pi 模型状态与可选系统通知。目前 UI 使用中文。Agent 规则、模型请求与建议状态持久化由 Node sidecar 负责。

Debug 应用在 Finder 和 Dock 固定使用夜间图标，Release 应用固定使用日间图标，不随外观切换。侧栏 Logo 随应用的日间、夜间或跟随系统设置切换，菜单栏使用同一标志的单色模板。品牌资源来自 [Resources](Sources/AnotherYouCore/Resources)。

## 从源码运行

应用支持 macOS 14+；从源码构建需要完整 Xcode 27+、macOS 27+ SDK、Node.js 22.19+ 和 npm。从仓库根目录执行：

```bash
make deps
make run
```

`make run` 以 Debug 配置构建并启动 `dist/dev/Another You.app`，显示名称为 **Another You Debug**，Bundle ID 为 `com.anotheryou.mac.debug`，进程记录和日志放在同一目录；启动诊断见 `dist/dev/another-you.log`。

```bash
make stop
make update
```

调试应用默认使用 `~/Library/Application Support/AnotherYouDebug/`，与 Release 应用的配置、状态和偏好分开；设置 `ANOTHER_YOU_DATA_DIR` 可覆盖数据路径。

`make stop` 停止本工作区管理的开发实例。`make update` 按本地源码重建并重启 Debug 应用，不拉取 Git 更新。`make build-package` 生成独立的 Release 应用包；内置 Node 的说明见 [打包文档](../../docs/releasing.zh-CN.md)。

不使用应用包、直接进行 Swift 开发时：

```bash
ANOTHER_YOU_AGENT_ROOT="$PWD/agent-core" \
  ./scripts/xcode-toolchain.sh run --package-path macos/AnotherYou AnotherYou
```

直接运行可使用主界面和 sidecar，但系统通知需要 `.app` 应用包。可从菜单栏退出应用；前台源码运行也可用 `Ctrl+C` 结束。

构建和测试使用 `DEVELOPER_DIR` 或 `xcode-select` 选定的完整 Xcode；仅有 Command Line Tools 或 Xcode 低于 27 时会拒绝执行。`make build SWIFT_SCRATCH_PATH=/tmp/another-you-swift` 和 `make test-swift SWIFT_SCRATCH_PATH=/tmp/another-you-swift` 可将验证产物与默认 `.build` 隔离，验证后单独清理该临时目录。

## 使用 Pi 模型

设置按通用、模型、主动建议、电脑操作、快捷键、软件更新分页。电脑操作与后台浏览器能力默认启用，电脑操作页提供屏幕录制和辅助功能授权，浏览器没有单独的设置项。模型页直接管理应用独立的 Pi 模型与账户配置。

1. 在 **设置 → 模型** 选择提供方，或选择 **自定义 API** 添加兼容服务。
2. API 表单填写接口地址、协议、API Key 和模型 ID，点击 **保存并使用**；已有密钥默认遮挡，点击眼睛查看，留空保存可保留原密钥。同一提供方支持添加命名账户和切换完整配置。使用网页登录或其他认证方式时，完成认证后选择模型和思考深度，点击 **使用此模型**。
3. 点击 **测试连接**，核对实际请求结果；保存成功不代表服务可用。**导入 Pi 模型** 直接读取本机 Pi，无需选择文件；自定义 API 复用上方表单。

应用自动发现 Pi 的 `settings.json`、`models.json` 和 `auth.json`，默认目录为 `~/.pi/agent`，遵循 `PI_CODING_AGENT_DIR`。首次有效发现将模型与账户复制为独立的 `<dataDir>/pi/models.sqlite` 数据库快照，应用已有配置优先；后续源文件变动不覆盖应用选择或恢复已注销账户。没有本机 Pi 时仍可在设置中配置。旧 Another You 配置中的 `model` 不再生效，也不会写回个人 Pi。缺少默认模型或认证时明确提示；读取成功不等于模型请求已验证。模型请求仍通过 Pi 的原生认证与提供方适配执行。

## 会话与用量

快速会话显示高 44pt 的紧凑玻璃胶囊输入框，黑色遮罩从顶部向底部渐隐，位于鼠标所在屏幕水平中央、距屏幕底部 20% 处。macOS 26+ 使用原生液态玻璃，更早版本回退磨砂玻璃。右侧保留红色关闭和蓝色运行按钮，关闭后保留草稿；有截图时在上方显示可移除的附件预览。Return、发送快捷键或运行按钮提交后收起，回复在主界面会话中查看。

侧边栏的 **会话** 打开独立会话页。应用运行时，**⌘⇧Space** 在其他应用中也能呼出快速会话框；**⌘Return** 发送，**Esc** 隐藏小窗口。每次唤起快速会话框都会分配独立会话，发送后出现在看板；打开或关闭而未发送不会产生空记录，关闭仍保留未发送的草稿。新会话可与旧会话同时运行，返回看板、切换会话和再次唤起输入框都不会停止旧任务；详情中的停止只取消该会话。已发送的会话保留在看板中，打开历史会话即可继续讨论。快捷键注册失败时可使用菜单的快速会话入口。每个会话最近 20 轮成功对话作为自身的后续请求上下文，不混入其他会话或建议草稿。会话标题、状态与完整消息历史由 sidecar 持久化，重启恢复遵循内容保存偏好；截图二进制不持久化，也不会在后续轮次假装重传。

**会话** 页面以 **进行中 / 已完成** 两列展示会话和主动建议，可按快照关联的应用分组。三点菜单提供置顶／取消置顶、归档／恢复和删除；置顶项在当前列及应用分组内优先显示，并跨重启保留。搜索匹配会话和建议的标题或关联应用名，不区分大小写，并忽略查询前后的空白。搜索时直接显示匹配的归档项，清空后恢复完整看板及原来的归档展开状态。会话页的 **已归档会话** 默认折叠，可展开后查看、恢复或删除。

看板下方的新会话输入框与看板分隔，首次发送后才创建会话；切换时保留各自未发送的文字和快照附件。点击会话进入详情，查看完整上下文、继续讨论、导出，或从某一轮／整个会话创建独立分支。回复支持 CommonMark / GFM：六级标题、强调、删除线、多层列表、任务列表、引用、分隔线、表格对齐、自动及引用链接、图片、代码高亮和安全 HTML 排版，正文可选中复制；另外支持 KaTeX 数学公式（美元符号、\(…\)、\[…\]、数学环境和 math/latex 围栏）、Mermaid 图及脚注。长代码和宽表格在回复内横向滚动。归档详情可直接恢复后继续；分支保留来源，不修改原会话或重复计入用量。点击建议可查看并决定下一步。执行中的会话需先停止，所有操作以 sidecar 回执为准。会话 Markdown 与首页用量 CSV 的内容和限制见 [导出说明](../../docs/exporting.zh-CN.md)。

Markdown 解析器、KaTeX 字体、Mermaid 和 HTML 清洗器随应用离线打包；远程图片仍需网络，不执行回复中的脚本或嵌入页面。渲染源码在 `MarkdownRenderer/`，可用 `npm ci --prefix macos/AnotherYou/MarkdownRenderer --ignore-scripts`、`npm run build --prefix macos/AnotherYou/MarkdownRenderer` 重建随包资源，用 `npm test --prefix macos/AnotherYou/MarkdownRenderer` 验证语法；`make test-swift` 另外验证真实 WebKit 渲染。

**活动记录** 按条显示思考、执行、运行命令和读取应用上下文的阶段，可按类型筛选或分组；思考日志只记录开始/结束状态，不保存模型的思考正文。

首页饼图显示模型 Token 占比，支持 **24h / 7d / 15d / 30d**，并列出输入、输出、缓存、模型排行、思考深度和工具调用。统计从本版本开始，保留 186 天；失败请求已报告的用量也会计入。服务未报告用量时显示未报告，不估算。Plugin / Skill / MCP 仅在运行时确有对应调用记录时显示，当前没有内置这些连接器。

首页 **使用统计** 提供最近 **6 个月** 的每日 Token 热力图，按 **50M / 100M / 150M / 200M / 250M** 固定阈值着色（M 为百万 Token）；服务未报告用量时单独标识，已报告的零值与缺失值区分。方格随可用宽度自动铺满，无需选择时间范围，直接汇总全部应用及未关联应用的记录。下方折线图和柱状图继续统计当天本地小时及应用触发次数。每次接受的会话发送与每条首次出现的主动建议各计一次；后台分析、建议再次提醒或执行、会话分支不重复计入。应用归属来自本次快照、已有会话关联或建议上下文，缺失时显示未关联应用。统计元数据独立保留 186 天，归档或删除会话不改变次数；升级时仅迁移仍存在的历史事件，已清理的历史不补算。

## 建议与通知

建议结合运行中的应用与进程、关联项目、打开的文档和多个窗口、近期文件与本机浏览记录，以及可访问通知来理解工作。**设置 → 主动建议 → 工作与通知 → 回看范围** 可选择 **24h / 7d / 30d**，默认 24h。采集不依赖当前前台屏幕，较长内容分批分析；仅有元数据或权限不足的来源会明确标记。应用启动、本地时间和真实闲置信号仍可触发规则，闲置每 30 秒采样一次，冷却与未处理建议共同限制重复打扰。

建议支持 **生成草稿**、**稍后** 和 **忽略**。稍后默认延迟 15 分钟；到期时，运行时需保持运行，主动调度已启用且未暂停，建议才会恢复。生成状态以 sidecar 的回执为准，失败可由用户手工重试。**暂停主动建议** 跨重启保存，不取消已经提交的模型请求。

主动建议与系统通知默认开启，已有暂停、配置关闭及通知偏好保持不变。打包应用处于前台且通知偏好开启时，会自动申请尚未决定的通知权限，无需等待 Agent 连接或恢复主动建议；在 **设置 → 主动建议** 开启通知也会申请权限。Agent 连接、建议已启用且未暂停时，仍会为读取工作与通知文本自动申请一次辅助功能权限。拒绝通知权限后关闭通知偏好；拒绝辅助功能后不会反复弹窗，可在 **设置 → 主动建议 → 辅助功能** 再次手动授权。文本采集不需要屏幕录制权限，快照仍在电脑操作设置中单独授权。应用非活跃且主动建议未暂停时，新建议事件才尝试通知；加载已保存卡片不会通知。macOS 设置与专注模式可能影响送达，开启选项不代表通知已成功送达。

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
