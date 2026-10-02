# Another You

[English](README.md) | **简体中文**

一个只面向 macOS 的私有化、本地优先个人 AI 助手。在合适的时间提出下一步，让你决定生成草稿、稍后提醒或忽略。

SwiftUI 负责原生窗口、菜单栏和设置，Node sidecar 负责规则、状态持久化与官方 Pi SDK 模型请求。目前应用和官网使用中文，项目文档提供中英文版本。

**当前为 0.1.0 开发预览。** GitHub 和 Gitee 仓库已开源。应用内更新与发布工具已实现；首个公开安装包和 Homebrew cask 尚未发布。

[快捷键、截图与后台操作](docs/desktop-automation.zh-CN.md)

## 当前能力

| 能力 | 已实现行为 |
| --- | --- |
| 主动建议 | 从应用启动、本地时间和 Mac 的实际闲置时长触发，带来源说明、冷却与去重。 |
| 主动工作分析 | 默认每 5 分钟读取可访问的当前工作窗口、每 3 分钟检查可访问的通知内容；子 agent 分析，父 agent 每 10 分钟汇总，建议至少间隔 15 分钟。 |
| 用户决定 | 生成可审阅草稿、15 分钟后提醒、忽略或暂停主动建议；处理状态与暂停状态跨重启保存。 |
| 模型请求 | 连接本机 OpenAI 兼容服务；可通过配置显式授权远程服务。 |
| 系统通知 | 从打包后的 `.app` 中主动开启并取得 macOS 授权后，可在应用非活跃时提示新建议。 |
| 软件更新 | 正式配置的应用支持检查更新、自动下载和任务结束后自动安装；开发包禁用在线更新。 |
| 本地记录 | 保存建议状态和有数量上限的活动记录，可配置内容保存与基础凭据遮盖。 |

支持用户主动截图、应用上下文、电脑操作和独立后台浏览器；具体权限与限制见[操作指南](docs/desktop-automation.zh-CN.md)。主动工作分析只读取辅助功能允许访问的当前窗口和通知中心内容，不截图、不读磁盘文件；没有权限或通知已消失时会明确显示不可访问。模型也可使用文件、Shell 和网络工具。建议出现不代表模型可用；会话保留当前进程内最近 20 轮成功对话作为后续上下文。Calendar、Mail、Notes 尚无专用连接器。

## 快速开始

应用支持 macOS 14+；从源码构建需要完整 Xcode 27+、macOS 27+ SDK、Node.js 22.19+ 及 npm。生成草稿还需要兼容的本机模型服务和已安装模型；只查看规则建议不需要模型。打包、发布测试和官网预览需要 Python 3。

从仓库根目录执行：

```bash
make deps
make run
```

`make run` 构建并启动 `dist/dev/Another You.app`。模型统一在本机 Pi 配置，包括本地模型；在 Pi `/model` 中按 Ctrl+S 保存默认模型后，在 **设置 → 模型** 点击 **重新读取 Pi 配置**。Another You 直接使用 Pi 的认证和模型设置。

保存配置不等于连接验证。提交一条提问或批准生成草稿后，才能验证模型请求是否成功；失败会显示在应用中。

```bash
make stop    # 停止本工作区启动的开发应用
make update  # 根据本地源码重建并重启，不执行 git pull
```

直接运行 Swift 与通知要求见 [macOS 指南](macos/AnotherYou/README.zh-CN.md)，模型设置、文件位置和环境变量见 [配置参考](docs/configuration.zh-CN.md)。

## 开发命令

运行 `make help` 查看可用目标。

| 命令 | 用途 |
| --- | --- |
| `make build` | 构建 Swift 可执行文件。 |
| `make check` | 检查 TypeScript、官网 JavaScript 与 Shell 语法。 |
| `make test` | 运行 Agent、Swift、开发脚本和发布工具测试。 |
| `make test-release` | 验证发布签名、元数据与双端上传流程。 |
| `make build-package` | 在 `dist/macos` 生成独立的开发 `.app`。 |
| `make website` | 在 `http://127.0.0.1:4173` 预览静态官网。 |
| `make pi-source` | 将锁定的上游源码拉取到 `agent-core/.cache/pi`。 |
| `make clean` | 停止受管理的开发应用，清理已知构建与测试产物。 |

`clean` 保留依赖、Pi 源码缓存、个人应用数据和自定义打包目录。打包脚本拒绝覆盖已有应用。输出位置、内置 Node 和 CI 产物见 [打包与发布现状](docs/releasing.zh-CN.md)。

## 隐私与权限

默认模型端点只允许本机回环地址。远程端点需要显式网络授权、精确的允许主机和 HTTPS。构建与安装依赖的命令可能访问 npm、GitHub，它们不受模型网络策略控制。

配置和状态通常位于 `~/Library/Application Support/AnotherYou/`，使用本机文件权限与可配置的存储规则，未实现应用层加密。遮盖只识别常见凭据模式，不能识别所有私人文本。具体边界见 [配置参考](docs/configuration.zh-CN.md) 与 [安全策略](SECURITY.zh-CN.md)。

## 文档

| 文档 | 内容 |
| --- | --- |
| [macOS](macos/AnotherYou/README.zh-CN.md) | 原生应用、设置、通知与排障 |
| [Agent 核心](agent-core/README.zh-CN.md) | 运行时开发与 Pi 接入 |
| [官网](website/README.zh-CN.md) | 静态预览与交互检查 |
| [配置参考](docs/configuration.zh-CN.md) | 模型、隐私、调度与环境变量 |
| [CLI 与 JSONL 协议](docs/cli-reference.zh-CN.md) | 命令、事件、规则和建议状态 |
| [架构](docs/architecture.zh-CN.md) | 数据流与实现边界 |
| [打包与发布现状](docs/releasing.zh-CN.md) | 开发构建与正式分发的剩余工作 |
| [来源](docs/sources.zh-CN.md) | 上游锁定、许可证与设计参考 |

## 参与贡献

代码、Issue 和 Pull Request 统一在 [GitHub](https://github.com/wzz6423/another-you) 管理。[Gitee](https://gitee.com/wzz6423/another-you) 仅用于镜像访问与版本发布，不接收 Issue 或 Pull Request。GitHub 到 Gitee 的镜像同步由仓库所有者另行配置。

参与前请阅读 [贡献指南](CONTRIBUTING.zh-CN.md)、[行为准则](CODE_OF_CONDUCT.zh-CN.md) 和 [安全策略](SECURITY.zh-CN.md)。

## 许可证

[MIT](LICENSE)。第三方依赖保留各自许可证，详见 [来源](docs/sources.zh-CN.md)。
