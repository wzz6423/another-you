# 来源与采用边界

[English](sources.md) | **简体中文**

本文记录上游代码与设计参考。参考产品的能力或宣传不能证明 Another You 已实现相同功能。

## Pi 代码与锁定

项目使用 [Pi](https://github.com/earendil-works/pi)，当前上游记录在 [pi-source.lock.json](../agent-core/pi-source.lock.json) 中，其中保留的旧地址为 `badlogic/pi-mono`。这是 Pi coding-agent 项目，与名为 clonepi 的树莓派磁盘克隆工具无关。

| 项目 | 锁定值 |
| --- | --- |
| 源码仓库 | `https://github.com/earendil-works/pi.git` |
| 解析时的源码分支 | `main` |
| 源码快照提交 | `e792ba131ed0495f3ff58a0eb13f20540e344d5c` |
| SDK 包版本 | `@earendil-works/pi-agent-core` 和 `@earendil-works/pi-ai`，均为 `0.99.2` |
| SDK 发布提交 | `005af57d88ee23b33778f343a9595b32e67ff788` |
| 源码锁解析日期 | `2026-10-01` |
| Pi 许可证 | MIT |

源码快照与 SDK 发布提交有意分开记录。[package.json](../agent-core/package.json) 选择实际运行的 SDK 版本，[package-lock.json](../agent-core/package-lock.json) 固定完整依赖树与完整性摘要。获取源码缓存不会替换这些依赖。

[Agent 包](https://github.com/earendil-works/pi/tree/e792ba131ed0495f3ff58a0eb13f20540e344d5c/packages/agent) 提供 Agent/会话循环，[AI 包](https://github.com/earendil-works/pi/tree/e792ba131ed0495f3ff58a0eb13f20540e344d5c/packages/ai) 提供模型调用与流式处理。Another You 显式提供模型、系统提示词、空工具集和受限 fetch，Swift/Node 的 JSONL 协议由本项目定义。[Pi 扩展](https://github.com/earendil-works/pi/blob/e792ba131ed0495f3ff58a0eb13f20540e344d5c/packages/coding-agent/docs/extensions.md) 只作为未来受控定制的参考；本预览不加载用户扩展与技能。

## 检查或更新源码锁

从仓库根目录执行：

```bash
make pi-source
./agent-core/scripts/bootstrap-pi.sh --print
./agent-core/scripts/bootstrap-pi.sh --check
```

`make pi-source` 将锁定 SHA 拉取到被忽略的 `agent-core/.cache/pi`，以 detached HEAD 检出并核对最终 SHA。`--print` 不联网，只展示锁定文件。`--check` 比较锁定值与远端分支当前 HEAD；即使本地快照正确，上游前进后它也可能失败。该命令不检查本地源码缓存。

HTTPS Git 不可用、且已配置 GitHub SSH 时：

```bash
PI_GIT_TRANSPORT=ssh ./agent-core/scripts/bootstrap-pi.sh fetch
```

有意升级源码时，`./agent-core/scripts/bootstrap-pi.sh --refresh` 只更新源码锁里的 `commit` 与 `resolvedAt`，之后运行 `make pi-source` 拉取该快照。采用前需审阅上游变化。实际运行 SDK 的升级是另一件事，需要审阅 `package.json`、`package-lock.json` 和源码锁中的 SDK 字段，再运行 Agent 与 Swift 集成检查。

`PI_SOURCE_DIR` 和 `PI_SOURCE_LOCK` 可分别覆盖缓存与锁定文件路径。私有定制应放在独立工作区，或在切换快照前提交；脚本不会把私有源码修改合并到运行时。

## 产品参考

- [Today](https://today.ai/) 及其 [产品介绍](https://today.ai/articles/blog/what-is-today)：短简报、作为设计方向的可编辑记忆、选择合适时机主动参与，以及外部动作前的审阅。
- [Google Antigravity 总览](https://antigravity.google/docs/overview/) 与 [功能说明](https://antigravity.google/docs/features/)：以异步工作、计划工作、子 Agent、产物审阅和权限设计作为参考。初版实现时未完成实时视觉对照。

Another You 当前使用规则、本地状态和用户批准后的文本生成，没有自动长期对话记忆或外部动作工具。官网图形与文案由本项目创作，未包含参考站点的品牌素材。

## 工程与许可证

Zisla 的 Makefile、双语文档结构和 CI 模式为开发入口提供参考，包括针对性检查、最小工作流权限、并发取消和清理。没有复制它的发布系统、更新渠道、无关平台或 Project 自动化。Another You 的 Project 仅保留 Board 视图与字段；贡献工作在仓库 Issue 和 Pull Request 中进行。

开发技能是贡献者的工具，不会作为隐式提示词或权限装入用户的助手。第三方代码保留在 npm 包或独立源码缓存中，沿用各自许可证。项目的 [MIT 许可证](../LICENSE) 不替代依赖许可证。内置 Node 有独立许可证；[打包脚本](../scripts/build-app.sh) 会在存在相邻 `LICENSE` 时复制它，正式分发前仍需检查许可内容。
