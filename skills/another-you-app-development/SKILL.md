---
name: another-you-app-development
description: 开发、修复或评审 Another You 的原生 macOS 应用、Node/Pi sidecar、官网与开发脚本时使用。覆盖 SwiftPM/SwiftUI 与 JSONL 边界、实际窗口验证、针对性测试和产物清理；正式发布使用 another-you-release。
---

# Another You 开发

从当前 Another You checkout 根目录执行命令。全局安装的 Skill 软链只用于发现，不把软链父目录当作仓库根。开始先记录 `git status --short`，阅读适用的 `AGENTS.md`、[贡献指南](../../CONTRIBUTING.zh-CN.md) 和相关实现；保留用户及并行任务已有修改。

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
make build          # Swift 可执行文件
make run            # 构建并启动 dist/dev/Another You.app
make update         # 本地源码重建并重启，不执行 git pull，也不是应用在线更新
make stop           # 停止本工作区管理的开发实例
make build-package  # 生成开发 .app；输出目录已有应用时拒绝覆盖
make website        # 预览官网；PORT 可覆盖
make pi-source      # 仅需阅读锁定上游源码时使用
```

`run/update` 会替换本工作区受管理的运行实例；启动前确认这符合本次要求。一次性验证优先用新 `OUTPUT_DIRECTORY` 打包，避免替换用户正在使用的应用。默认 `BUNDLE_NODE=1` 会按 `scripts/runtime-dependencies.json` 下载并校验官方 Node 与后台浏览器，随包携带 npm、生产依赖和许可证。`ANOTHER_YOU_NODE` 覆盖必须指向完整官方发行目录的 `bin/node`，该目录需要 `include/node/node_version.h`、`lib/node_modules/npm` 与许可证；Node `LICENSE` 可用 `ANOTHER_YOU_NODE_LICENSE` 指定。不能只复制依赖外部动态库的 Homebrew Node。只有显式 `BUNDLE_NODE=0` 才使用本机 Node/浏览器，不能分发这种包。正式发布走[发布 Skill](../another-you-release/SKILL.md)。

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

## 清理与交付

- 清理本次创建的 binary、构建目录、截图、日志、临时配置和测试进程；保留用户要求继续运行的应用、交付文件、依赖与 Pi 缓存。
- `make clean` 会停止受管理的 `dist/dev` 应用，并清理 Swift `.build`、默认开发包等共享产物；只有这些内容属于本次验证或用户要求整体清理时才执行。自定义输出另行按准确路径删除。
- 不删除 `~/Library/Application Support/AnotherYou/`、用户偏好或运行中的其他实例来“恢复测试环境”。不要提交凭据、用户数据或构建产物。
- 完成后检查 `git diff --check`、实际 diff 和 `git status --short`，报告修改文件、执行过的验证、结果与未验证范围。子执行器的结论必须由主线程检查 diff 并独立验证。
- 开发、Issue 和 PR 使用 GitHub，Gitee 用作源码与发布镜像。GitHub Project 只保留既有视图与字段，不新建任务卡或自动把 Issue/PR 加入看板。开发请求不自动包含发版、修改 tap 或改变仓库可见性的授权。

更改已记录行为、命令和设置时同步对应中英文文档；项目 Skill 本身采用中文。
