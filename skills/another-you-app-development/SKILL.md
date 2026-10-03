---
name: another-you-app-development
description: 开发、修复或评审 Another You 的原生 macOS 应用、Node/Pi sidecar、官网、开发脚本与开发规范时使用，也适用于维护本项目的 Git 提交说明。覆盖 Claude Code 协作、针对性验证与清理；正式发布使用 another-you-release。
---

# Another You 开发

从当前 Another You checkout 根目录执行命令。全局安装的 Skill 软链只用于发现，不把软链父目录当作仓库根。开始先记录 `git status --short`，阅读适用的 `AGENTS.md`、[贡献指南](../../CONTRIBUTING.zh-CN.md) 和相关实现；保留用户及并行任务已有修改。

## 开发工作方式

- 全程用中文沟通，Git 提交说明的语言按下文执行。先浏览项目结构与模块划分，阅读修改涉及的实现、测试及配置，识别现有工具函数、组件、编码风格和设计模式，不跳过阅读直接修改。
- 动手前列出必要的修改位置（`文件:行号`）、原因、影响范围、方案与验证方法。分析充分后直接修改、调试和 debug，不为已经明确或已经授权的工作重复请求确认。
- 需求不清楚、实现意图不确定或存在需要用户取舍的多个方案时，先说明问题并询问，不猜测；有多个方案时列出选项及影响。发现影响当前任务的代码问题直接修复，无关问题先说明，不扩大修改范围。
- 只改必要代码，优先复用项目已有能力，遵循现有风格。仅在逻辑不自明时添加注释，解释为什么，不重复代码已经表达的内容。
- 按小步骤推进。每次进度更新包含估算百分比、当前操作、涉及文件或处理数量、中间结果和下一步；每完成一个子步骤或一小批操作就更新，长时间操作期间至少每 60 秒说明一次，遇到问题及时说明。百分比仅表示任务进度估计，不能代替实际验证结果。

## Claude Code 自动协作

- 非平凡任务尽早使用 Claude Code 协作，包括开发、排障、测试失败、复杂重构、迁移、评审后修复、陌生代码探索、方案与风险判断，以及文档、配置或提示词修改。非常小、纯文本、单条命令即可完成，或结论明确且风险很低的任务可以直接完成，不强行委派。
- 子智能体默认沿用父智能体的模型和思考深度；简单的文本探索、阅读与编辑任务可以使用更轻量的配置。Claude Code 使用当前可用配置。
- 委派任务必须收敛且可验证，写明五项执行契约：只改指定范围、复用现有模式、实际落地修改、运行明确的 UT 及按风险需要的集成或 E2E 命令、清理本次构建与 binary 及临时产物。验证命令按下文的修改边界选择，纯文档不要求客户端测试。
- 除用户明确要求纯审查、纯分析或禁止修改外，实现、排障、验证和评审后修复子任务必须阅读相关代码、直接写最小补丁并运行验证；失败时继续 debug 到通过，或给出明确阻塞证据，不停在只读建议。返回修改文件、测试命令、成功与失败数、清理状态和残余风险。
- Claude Code 后台工作通过可持续终端 session 执行并持续轮询；除用户要求停止或确认不可恢复错误外，不因等待较久而中止。出现额度、usage/rate limit、billing/credit、渠道或 provider、鉴权、模型不可用或连续网络失败时，本任务内停止重试，由主线程继续完成。
- 主线程必须检查实际 `git diff`，决定是否采用执行器的修改，并独立重跑相关验证、检查清理结果；不能只转述执行器的“通过”，最终结论由主线程负责。

## 按修改范围阅读

| 范围 | 实现与必要上下文 |
| --- | --- |
| 原生窗口、菜单和设置 | `macos/AnotherYou/Sources/AnotherYou/main.swift`、`AnotherYouCore/MainWindowView.swift`、`AssistantStore.swift`；[macOS 指南](../../macos/AnotherYou/README.zh-CN.md)。 |
| Swift 与 Node 通信 | `AnotherYouCore/AgentClient.swift`、`Models.swift`、`agent-core/src/cli.ts`、`events.ts`；[JSONL 协议](../../docs/cli-reference.zh-CN.md)。 |
| 规则、状态、模型与隐私 | `agent-core/src/index.ts`、`scheduler.ts`、`state.ts`、`config.ts`、`pi-adapter.ts`；[架构](../../docs/architecture.zh-CN.md) 和[配置](../../docs/configuration.zh-CN.md)。 |
| 构建、开发生命周期、自动更新 | [Makefile](../../Makefile)、`scripts/build-app.sh`、`scripts/dev-service.sh`、`AnotherYouCore/UpdateController.swift`、`scripts/release.py`；[发布指南](../../docs/releasing.zh-CN.md)。 |
| 官网 | `website/index.html`、`styles.css`、`script.js`；[官网指南](../../website/README.zh-CN.md)。 |

表中 `AnotherYouCore/` 指 `macos/AnotherYou/Sources/AnotherYouCore/`。沿调用边界读相关测试，先复用现有类型、状态和工具，再写最小修改。不要引入 Zshell 的 Xcode 工程、终端后端或 Zisla 的客户端架构。

## 保持实际产品边界

- 客户端使用 SwiftPM、Swift 6、SwiftUI/AppKit，最低 macOS 版本以 `Package.swift` 为准。设置是可最小化、关闭并重新打开的独立窗口，主窗口可继续操作；使用系统窗口控件。界面只保留帮助完成操作的文案，排障、架构和隐私长说明放文档。
- Node.js 22.19+ 直接擦除 TypeScript；npm 包和 `package-lock.json` 决定运行依赖。Pi 阅读缓存由 `pi-source.lock.json` 锁定，不等于运行时依赖，也不替代 npm SDK。
- stdout 只输出协议 JSONL，诊断写 stderr。Swift 状态以 sidecar 回执为准，不能把命令发送成功当执行成功。更改协议时同时检查 Swift 解码与 Node 发出端。
- 规则产生建议不代表模型可用；配置保存不代表模型连接成功。模型工具与网络能力以当前 `config.ts`、`pi-adapter.ts` 和实际工具注册为准；修改权限时核对默认值、用户授权、允许范围与拒绝路径，不从配置名称推断能力已经实现。
- 自动下载与自动安装是不同偏好。更新不能中断正在生成的草稿；应用终止路径应先结束 sidecar 并保存状态。改更新代码后需检查正式包验证路径，开发包不能证明线上更新有效。

## 开发命令

先读当前 `Makefile` 和相关脚本，再执行下列现有目标：

```sh
make deps           # 安装锁定的 Agent 开发依赖
make check          # TypeScript、官网 JavaScript 与 Shell 语法
make build          # 仅编译 Debug Swift 可执行文件，不打包或启动
make run            # 构建并启动 Debug 应用 dist/dev/Another You.app
make update         # 本地源码重建并重启 Debug 应用，不执行 git pull，也不是应用在线更新
make stop           # 停止本工作区管理的开发实例
make build-package  # 打包 Release .app；输出目录已有应用时拒绝覆盖
make website        # 预览官网；PORT 可覆盖
make pi-source      # 仅需阅读锁定上游源码时使用
```

`run/update` 固定使用 Debug 配置并禁用在线更新，显示名称为 Another You Debug，Bundle ID 为 `com.anotheryou.mac.debug`，默认数据目录为 `~/Library/Application Support/AnotherYouDebug/`（`ANOTHER_YOU_DATA_DIR` 可覆盖）。Debug 产物包含独立 `.dSYM`，`update` 同步替换，`clean` 一并清理。`build-package` 固定使用 Release，默认仍为 ad-hoc 签名且禁用在线更新。`run/update` 会替换本工作区受管理的运行实例；启动前确认这符合本次要求。一次性验证优先用新 `OUTPUT_DIRECTORY` 打包，避免替换用户正在使用的应用。默认 `BUNDLE_NODE=1` 会按 `scripts/runtime-dependencies.json` 下载并校验官方 Node 与后台浏览器，随包携带 npm、生产依赖和许可证。`ANOTHER_YOU_NODE` 覆盖必须指向完整官方发行目录的 `bin/node`，该目录需要 `include/node/node_version.h`、`lib/node_modules/npm` 与许可证；Node `LICENSE` 可用 `ANOTHER_YOU_NODE_LICENSE` 指定。不能只复制依赖外部动态库的 Homebrew Node。只有显式 `BUNDLE_NODE=0` 才使用本机 Node/浏览器，不能分发这种包。正式发布走[发布 Skill](../another-you-release/SKILL.md)。

## 验证改变的边界

| 修改内容 | 验证 |
| --- | --- |
| Agent、模型策略或配置 | `make check`、`make test-agent`；覆盖变更涉及的主机限制、状态或并发行为。 |
| Swift、JSONL 或 sidecar 生命周期 | `make test-swift`；先安装 Agent 依赖，因为测试包含真实 Node 进程。 |
| 开发生命周期脚本 | `make test-scripts`；打包改动还需生成并运行实际 `.app`。 |
| 发布工具或更新打包 | `make test-release`、`bash -n scripts/build-app.sh`，以及受影响的真实构建/签名验证；设置 `SPARKLE_BIN` 时还运行官方 Sparkle 工具集成测试。 |
| 更新下载、安装与退出行为 | `make test-swift`、`make test-updater-install`；后者在临时应用与本机 HTTP 通道中运行实际 Sparkle 安装，不接触个人安装。 |
| 官网 | `make check`，按官网指南实际操作改变的页面及窄窗口布局。 |
| 纯文档、Skill | 检查本地链接、命令与实现一致性；文档保持中英文配对，不为文案重跑客户端测试。 |

SwiftUI 修改需要运行应用并实际操作：设置从侧栏、菜单及快捷键打开，最小化、关闭、重开；同时确认主窗口可用。验证范围随改动收敛，不仅报告“构建通过”。

模型测试使用本地 HTTP fixture；通过只证明 fixture 下的行为。真实模型兼容性要提交实际请求，系统通知要检查实际送达，自动更新要走真实签名 feed、下载、替换与重启。未执行的项目明确写未验证，不用单元测试或 CI 代替。

`make test-updater-install` 使用临时密钥和独立偏好，覆盖自动安装、忙碌延后、仅下载、签名拒绝和主/备用源切换，并自行清理。它验证实际安装器的本机流程，正式 HTTPS 源、发布签名身份及各目标架构分发仍需另验。`make test-release` 已包含在 `make test`，真实安装测试需显式运行。

隔离应用数据用 `ANOTHER_YOU_DATA_DIR` 指向本次临时目录；它不会隔离 `UserDefaults`。若验证涉及更新或通知偏好，应使用测试注入的独立 defaults 域，或记录并恢复改动的偏好，不能清空用户默认域。

## Git 提交规范

- 与用户沟通和项目 Skill 使用中文；所有 Git commit 的标题与正文使用英文，新增、amend、merge 和 squash 提交均适用。沿用已有的 `feat:`、`fix:`、`docs:`、`test:` 等提交风格，准确描述实际改动。
- 提交前检查 `git diff --cached` 和待提交说明，只包含本次任务的文件；保留用户及并行任务的未提交修改，不把英文提交规范当作自动提交、推送或改写历史的授权。
- 用户要求统一历史提交语言时，先检查所有目标分支、标签和远端，列出需要翻译的标题与正文，保留已经是英文的消息。改写前在工作区之外或 `.git` 内保存可恢复的原历史备份；仅改变消息及必要的父提交引用，保留各提交的文件树、作者、提交者和时间。
- 改写后逐条核对提交数量、文件树、作者与时间、父子拓扑和完整消息，并核对工作区及暂存区内容。仅修改提交消息时使用这些 Git 校验，不为此运行客户端构建或测试。
- 同步已发布历史前，先完成可审阅的英文消息、备份和本地验证，说明目标远端、分支及提交哈希变化；已有明确授权则直接执行，否则在推送前请求确认。使用带精确预期旧 SHA 的 `--force-with-lease`，远端发生变化时停止覆盖；推送后查询目标远端验证结果。

## 清理与交付

- 清理本次创建的 binary、构建目录、截图、日志、临时配置和测试进程；保留用户要求继续运行的应用、交付文件、依赖与 Pi 缓存。
- `make clean` 会停止受管理的 `dist/dev` 应用，并清理 Swift `.build`、默认开发包等共享产物；只有这些内容属于本次验证或用户要求整体清理时才执行。自定义输出另行按准确路径删除。
- 不删除 `~/Library/Application Support/AnotherYou/`、用户偏好或运行中的其他实例来“恢复测试环境”。不要提交凭据、用户数据或构建产物。
- 完成后检查 `git diff --check`、实际 diff 和 `git status --short`，报告修改文件、执行过的验证命令、成功与失败数、清理结果、未验证范围和残余风险。子执行器的结论必须由主线程检查 diff 并独立验证。
- 开发、Issue 和 PR 使用 GitHub，Gitee 用作源码与发布镜像。GitHub Project 只保留既有视图与字段，不新建任务卡或自动把 Issue/PR 加入看板。开发请求不自动包含发版、修改 tap 或改变仓库可见性的授权。

更改已记录行为、命令和设置时同步对应中英文文档；项目 Skill 本身采用中文。
