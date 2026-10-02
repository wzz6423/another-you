# Another You 贡献指南

[English](CONTRIBUTING.md) | **简体中文**

欢迎参与开源项目。开发统一使用 GitHub；Gitee 仅提供镜像访问与版本发布。

GitHub Project 仅保留 Board 视图与字段配置，不新建任务卡，也不自动将 Issue 或 Pull Request 加入看板。Issue 与 Pull Request 继续在 GitHub 仓库正常开展。

## 反馈问题或提出改动

提交前先搜索现有 [GitHub Issues](https://github.com/wzz6423/another-you/issues)。报告请包含提交或版本号、macOS 与 CPU 架构、Node 和 Swift 版本、启动方式、复现步骤、预期和实际表现。模型相关问题请说明提供方与模型名称，不要附带凭据或私人提示词。

功能建议说明用户遇到的问题和最小可用行为。漏洞按 [安全策略](SECURITY.zh-CN.md) 私下报告，行为问题按 [行为准则](CODE_OF_CONDUCT.zh-CN.md) 处理。共享日志或截图前，移除个人路径、令牌和私人内容。

## 准备工作区

环境要求和首次启动见 [根目录 README](README.zh-CN.md)。以下命令均从仓库根目录运行：

```bash
make deps
make check
make test
```

Node 测试使用本地 HTTP fixture，不需要真实 API 密钥或下载模型。Swift 测试包含真实 Node sidecar，因此应先安装 Agent 依赖。针对单个模块可使用 `make test-agent`、`make test-swift` 或 `make test-scripts`。

## 保持修改收敛

- 修改前阅读相关实现，优先复用已有工具和模式。
- 每个分支与 Pull Request 聚焦一个目标，使用 `fix/sidecar-startup`、`docs/configuration` 等清晰名称。
- 说明行为为何改变，不夹带无关清理。
- 调整已记录的行为、命令、设置或构建流程时，同步更新两种语言。英文页链接英文页，中文页链接中文页。
- 只有在明确设计并验证新权限边界时才增加模型工具。一个配置开关不代表已实现相应能力。

## 验证与提交

Pull Request 应说明问题、最终行为、修改范围、验证命令与结果，并列出失败或未执行的原因及残余风险。AI 辅助贡献同样需要代码审阅与独立验证。

| 修改范围 | 相应验证 |
| --- | --- |
| Agent 行为或配置 | `make check` 与 `make test-agent`，覆盖改变的隐私、状态或协议边界。 |
| Swift 或 JSONL 集成 | `make test-swift`，并手工检查受影响的应用交互。 |
| 开发脚本 | `make test-scripts`，并在 macOS 上执行相应构建或生命周期路径。 |
| 官网 | `make check` 与 [浏览器交互检查](website/README.zh-CN.md#验证)。 |
| 纯文档 | 检查本地链接、双语配对、示例和源码事实；仅修改文案无需运行时测试。 |

自动化测试不能证明视觉质量、真实模型兼容性、系统通知送达或正式分发可用，应单独记录对应的手工验证。托管检查以现有 [CI 工作流](.github/workflows/ci.yml) 为准，项目没有文档化的 PR 标签或跳过 CI 自动化。

提交前执行：

```bash
make clean
git diff --check
git status --short
```

清理自己生成的临时报告、日志、fixture 和自定义构建输出。`make clean` 保留 `agent-core/node_modules`、`agent-core/.cache/pi`、个人应用数据及自定义打包目录，需要时另行检查。不要提交 binary、`.env`、凭据、私人数据或第三方源码缓存。

开发 `.app` 输出见 [打包说明](docs/releasing.zh-CN.md)，模块职责见 [架构](docs/architecture.zh-CN.md)。
