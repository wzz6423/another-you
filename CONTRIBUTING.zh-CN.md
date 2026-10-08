# Another You 贡献指南

[English](CONTRIBUTING.md) | **简体中文**

欢迎参与开源项目。开发统一使用 GitHub；Gitee 仅提供镜像访问与版本发布。

GitHub Project 仅保留 Board 视图与字段配置，不新建任务卡，也不自动将 Issue 或 Pull Request 加入看板。Issue 与 Pull Request 继续在 GitHub 仓库正常开展。

## 反馈问题或提出改动

提交前先搜索现有 [GitHub Issues](https://github.com/wzz6423/another-you/issues)。使用 [Bug report](.github/ISSUE_TEMPLATE/bug_report.yml) 或 [Feature request](.github/ISSUE_TEMPLATE/feature_request.yml) 表单，标题保留 `[Bug]` 或 `[Feature]` 前缀并补充具体摘要。表单回答与 PR 正文可以使用中文或英文，保留表单生成的字段标题。

Bug 报告必填 Another You 版本或提交号、macOS 版本与 CPU、安装或启动方式、复现步骤、预期表现、实际表现和提交确认项。Node 与 Swift 版本是源码构建或工具链问题的可选信息；提供方与模型名称是模型问题的可选信息。功能建议必填用户遇到的问题和最小可用的预期行为。

两种表单均须选择一个区域：

| 区域 | 自动管理的标签 |
| --- | --- |
| macOS App | `area:macos` |
| Agent & Models | `area:agent` |
| CI & Build | `area:ci-build` |
| Website | `area:website` |
| Documentation | `area:docs` |

漏洞按 [安全策略](SECURITY.zh-CN.md) 私下报告，行为问题按 [行为准则](CODE_OF_CONDUCT.zh-CN.md) 处理。共享日志或截图前，移除个人路径、令牌、凭据、私人提示词和个人内容。

Issue 自动化根据表单同步 `bug` 或 `enhancement` 标签及区域标签。元数据缺失或不符合格式时，会加上 `needs-more-info` 并用评论说明需要补充的字段；编辑 Issue 后更新原评论，填写完整后移除该标签。请直接填写表单字段，注释、代码示例、占位符和重复段落不能满足必填要求。

## 准备工作区

环境要求和首次启动见 [根目录 README](README.zh-CN.md)。以下命令均从仓库根目录运行：

```bash
make deps
make check
make test
```

Node 测试使用本地 HTTP fixture，不需要真实 API 密钥或下载模型。Swift 测试包含真实 Node sidecar，因此应先安装 Agent 依赖。针对单个模块可使用 `make test-agent`、`make test-swift` 或 `make test-scripts`。

`make test-agent` 与 `make test-swift` 将 Pi 自动发现隔离到临时目录，并在退出时清理，避免测试读取个人 Pi 账户。直接筛选测试时也使用同一入口：`./scripts/run-isolated-tests.sh ./scripts/xcode-toolchain.sh test --package-path macos/AnotherYou --filter LocalizationTests`。

## 保持修改收敛

- 修改前阅读相关实现，优先复用已有工具和模式。
- 每个分支与 Pull Request 聚焦一个目标，使用 `fix/sidecar-startup`、`docs/configuration` 等清晰名称。
- 说明行为为何改变，不夹带无关清理。
- 调整已记录的行为、命令、设置或构建流程时，同步更新两种语言。英文页链接英文页，中文页链接中文页。
- 只有在明确设计并验证新权限边界时才增加模型工具。一个配置开关不代表已实现相应能力。

## Pull Request 格式

Git commit 标题与正文使用英文。PR 标题使用英文 Conventional Commit 格式，例如 `fix(agent): preserve session state on restart` 或 `ci: validate contribution metadata`。允许的类型为 `feat`、`fix`、`docs`、`style`、`refactor`、`perf`、`test`、`chore`、`build`、`ci` 和 `revert`。可选的 scope 使用小写字母、数字和连字符；可选的 `!` 表示破坏性改动。

使用 [PR 模板](.github/PULL_REQUEST_TEMPLATE.md)，保留以下五个标题：

- `Summary`：说明问题、最终行为和修改范围。
- `PR Type`：只保留一个 `- Type:`，与标题类型一致。
- `Validation`：每项检查以自己的 `- Status: passed`、`failed` 或 `not run` 开始。通过与失败的检查都要分别填写非空的 `- Command:` 和 `- Result:`；未执行的检查要填写自己的 `- Reason:`。手工检查在 `Command` 中描述实际步骤。
- `Risk and Rollback`：分别填写一个非空的 `- Risk:` 与 `- Rollback:`。
- `Related Issue`：使用 `Closes #123`、`Fixes #123` 或 `Resolves #123` 等关闭引用，每行一个；也接受完整 GitHub Issue URL。没有关联 Issue 时整段只写 `None`。

必填值必须是注释和代码块以外的可见文本。重复段落或字段（包括空的重复字段）均不合法。`passed` 记录贡献者填写的结果，格式检查不能证明命令确实执行过。AI 辅助贡献同样需要代码审阅与独立验证，并应说明仍未完成的验证。

标题示例：`docs: clarify contribution validation`。请将下面示例中的检查与结果替换为自己实际执行的内容：

```markdown
## Summary

明确贡献者在 Pull Request 中需要填写哪些验证信息。

## PR Type

- Type: docs

## Validation

- Status: passed
- Command: git diff --check
- Result: 没有空白格式错误。

- Status: not run
- Reason: 仅修改文档，没有改变应用行为。

## Risk and Rollback

- Risk: 贡献说明发生变化，应用行为不受影响。
- Rollback: 回退本次文档修改。

## Related Issue

None
```

PR 自动化同步类型标签，有关闭 Issue 的引用时加上 `development`，元数据不符合格式时加上 `needs-more-info`；编辑后更新既有反馈评论。这些标签不会创建 GitHub Project 任务卡。[PR Quality](.github/workflows/pr-quality-gates.yml) 使用仓库只读权限检查标题与正文，也适用于 fork 提交的 PR。

GitHub 的 `dependabot[bot]` 账户创建的 PR 豁免人工标题/正文模板和 `needs-more-info` 标签，构建、测试与安全检查照常执行。其他贡献者仍按正常元数据规则检查。

本地验证时，将标题和正文分别保存为 UTF-8 文件后执行：

```bash
ruby .github/scripts/pr-metadata.rb validate --title-file /tmp/pr-title.txt --body-file /tmp/pr-body.md
ruby .github/scripts/issue-metadata.rb validate --title-file /tmp/issue-title.txt --body-file /tmp/issue-body.md
```

## 验证与提交

按照改变的边界选择验证，说明失败或未执行的检查。

| 修改范围 | 相应验证 |
| --- | --- |
| Agent 行为或配置 | `make check` 与 `make test-agent`，覆盖改变的隐私、状态或协议边界。 |
| Swift 或 JSONL 集成 | `make test-swift`，并手工检查受影响的应用交互。 |
| 开发脚本 | `make test-scripts`，并在 macOS 上执行相应构建或生命周期路径。 |
| CI、模板或仓库自动化 | `make check-ci`、`make test-ci` 与 `make check-repository`。 |
| 官网 | `make check` 与 [浏览器交互检查](website/README.zh-CN.md#验证)。 |
| 纯文档 | 检查本地链接、双语配对、示例和源码事实；仅修改文案无需运行时测试。 |

自动化测试不能证明视觉质量、真实模型兼容性、系统通知送达或正式分发可用，应单独记录对应的手工验证。托管构建和测试以 [CI 工作流](.github/workflows/ci.yml) 为准。

### 托管检查

| 工作流 | 检查内容 |
| --- | --- |
| [CI](.github/workflows/ci.yml) | Agent 类型检查与测试；Swift/sidecar 和 Markdown renderer 测试；开发生命周期与发布工具测试；开发应用打包；官网语法与本地化测试。 |
| [CI Lint](.github/workflows/ci-lint.yml) | actionlint、Ruby 语法、元数据与自动化回归测试、仓库卫生检查，以及 zizmor 对工作流、本地 Actions 和 Dependabot 配置的安全审计。 |
| [PR Quality Gates](.github/workflows/pr-quality-gates.yml) | PR 标题与正文格式。 |
| [CodeQL](.github/workflows/codeql.yml) | GitHub Actions 与 JavaScript/TypeScript 的安全和质量分析。 |
| [Dependency Review](.github/workflows/dependency-review.yml) | 审查 PR 中的依赖变更。 |
| [Skill CI](.github/workflows/skill-ci.yml) | 项目 Skill 的元数据、结构与本地引用。 |

CI 根据变更路径选择运行时任务。已识别的纯文档改动省略 Agent、Swift 和官网运行时任务；Agent 改动同时运行 Swift sidecar 检查；原生代码运行 Swift 检查；官网资源运行官网检查。CI 配置、构建脚本、项目 Skill、Makefile、未知路径或无法完成比较时，运行完整的运行时测试集。其他工作流分别检查各自负责的范围。

`CI result` 使用稳定名称，确认被选择的运行时任务均成功，未运行的任务符合路径或维护者 gate 的决定。gate 失败会使该检查失败。是否设为合并必需检查，需要在仓库设置中单独配置。

[Dependabot](.github/dependabot.yml) 每周提出 GitHub Actions、Agent 和 Markdown renderer 的 npm 依赖更新。仓库卫生检查拒绝跟踪或暂存构建产物与私人配置。本地 CI 检查需要 Ruby 和 actionlint：`make check-ci` 检查语法，`make test-ci` 运行自动化测试，`make check-repository` 检查仓库卫生。

### 维护者 skip 与 unskip 指令

当前拥有仓库 `write`、`maintain` 或 `admin` 权限的维护者，在核对改动及验证证据后，可以通过 PR 评论发送指令。每条指令单独占一行，冒号后可写原因：

```text
skip-swift: 已在本机完成原生检查，结果与工具链版本记录在 Validation 中。
```

用 `unskip-swift` 恢复该目标。支持的简短指令如下：

| 目标 | 跳过 | 恢复 |
| --- | --- | --- |
| Agent core | `skip-agent` | `unskip-agent` |
| SwiftUI macOS | `skip-swift` | `unskip-swift` |
| Website and scripts | `skip-website` | `unskip-website` |
| CI Lint | `skip-lint` | `unskip-lint` |
| PR Quality Gates | `skip-quality` | `unskip-quality` |
| CodeQL | `skip-codeql` | `unskip-codeql` |
| Dependency Review | `skip-deps` | `unskip-deps` |
| Skill CI | `skip-skills` | `unskip-skills` |

`skip-ci` 选择 CI 中的三个运行时目标，`skip-all` 选择 [skip 清单](.github/ci-skip.json) 中的全部目标；`unskip-ci` 与 `unskip-all` 分别恢复相应组。也接受工作流完整名称和清单中声明的别名。PR 标题、正文、机器人评论、引用文本和代码示例中的指令不生效。

指令只对当前 PR head 生效。评论创建或编辑时间必须晚于 GitHub 为该 head 记录的一次 pull-request 工作流运行；尚无运行记录时，等待出现后重新发布或编辑指令。新提交会使旧决定过期。按评论更新时间、再按行顺序重放指令，后面的 skip/unskip 覆盖前面的决定；编辑或删除指令会重新计算。

[CI Skip 工作流](.github/workflows/ci-skip.yml) 更新一条状态评论和 `skip-ci` 标签。标签用于记录决定，手动添加标签不能取得跳过权限。决定变化后，取消受影响的活动运行并真正重跑工作流，由 gate 只省略选中的目标，其他检查正常执行；不会伪造成功检查，相同决定也不会反复触发重跑。gate 从默认分支读取解析器，解析器尚未出现在默认分支时正常运行检查。

机器人先保存当前提交的处理中记录，再取消和重跑；记录写入失败时检查正常执行。部分 API 操作失败后，可重新运行 CI Skip 继续恢复。

维护者也可执行 `gh workflow run ci-skip.yml --repo wzz6423/another-you --field pull-request=123`，将 `123` 替换为实际 PR 编号，重新应用现有评论的决定。该命令不会新建跳过指令，仍会重新核对作者权限和当前提交。

提交前执行：

```bash
git diff --check
git status --short
```

只清理本次工作生成的临时报告、日志、fixture、测试进程和自定义构建输出。`make clean` 会停止当前工作区管理的 `dist/dev` 应用并删除共享构建产物，只有这些资源属于本次测试或明确要求整体清理时才执行。它会保留 `agent-core/node_modules`、`agent-core/.cache/pi`、个人应用数据及自定义打包目录。不要中断他人正在使用的应用或删除个人数据。不要提交 binary、`.env`、凭据、私人数据或第三方源码缓存。

开发 `.app` 输出见 [打包说明](docs/releasing.zh-CN.md)，模块职责见 [架构](docs/architecture.zh-CN.md)。
