# Another You

[English](README.md) | **简体中文**

一个只面向 macOS 的私有化、本地优先个人 AI 助手。在合适的时间提出下一步，让你决定生成草稿、稍后提醒或忽略。

SwiftUI 负责原生窗口、菜单栏和设置，Node sidecar 负责规则、状态持久化与官方 Pi SDK 模型请求。目前应用和官网使用中文，项目文档提供中英文版本。

**当前为 0.1.0 开发预览。** GitHub 和 Gitee 仓库均为私有，需要访问权限。尚无公开安装包或自动更新渠道。

## 当前能力

| 能力 | 已实现行为 |
| --- | --- |
| 主动建议 | 从应用启动、本地时间和 Mac 的实际闲置时长触发，带来源说明、冷却与去重。 |
| 用户决定 | 生成可审阅草稿、15 分钟后提醒、忽略或暂停主动建议；处理状态与暂停状态跨重启保存。 |
| 模型请求 | 连接本机 OpenAI 兼容服务；可通过配置显式授权远程服务。 |
| 系统通知 | 从打包后的 `.app` 中主动开启并取得 macOS 授权后，可在应用非活跃时提示新建议。 |
| 本地记录 | 保存建议状态和有数量上限的活动记录，可配置内容保存与基础凭据遮盖。 |

尚未接入 Calendar、Mail、Notes 或屏幕内容。模型没有文件、Shell 或发送消息工具，生成草稿不会执行外部动作。建议由规则产生，出现建议不代表模型可用。每次模型请求都是独立的一轮，不会自动携带聊天记忆。

## 快速开始

需要 macOS 14+、Swift 6 工具链、Node.js 22.19+ 及 npm。生成草稿还需要兼容的本机模型服务和已安装模型；只查看规则建议不需要模型。Python 3 仅用于官网预览。

从仓库根目录执行：

```bash
make deps
make run
```

`make run` 构建并启动 `dist/dev/Another You.app`。打开 **设置 → 本地模型**，填写服务地址与实际安装的模型名称，再选择 **保存并重新连接**。Ollama 通常使用 `http://127.0.0.1:11434/v1`，可通过 `ollama list` 查看已安装模型。Another You 不会安装模型或启动模型服务。

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
| `make test` | 运行 Agent、Swift 和开发脚本测试。 |
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
