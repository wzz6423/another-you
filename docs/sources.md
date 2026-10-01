# 公开来源与采用边界

## 底层 Agent

- [Pi coding agent](https://github.com/earendil-works/pi)：当前官方上游，MIT；本项目通过 `agent-core/pi-source.lock.json` 锁定完整 commit，并由 `scripts/bootstrap-pi.sh` 拉取到忽略目录。
- [Pi Agent Core](https://github.com/earendil-works/pi/tree/main/packages/agent)：采用官方 Agent SDK，并显式注入模型、提示词和空工具集。Swift 与本项目 Node sidecar 使用自己的 JSONL 协议。
- [Pi AI](https://github.com/earendil-works/pi/tree/main/packages/ai)：复用模型调用及流式响应处理。源码 HEAD 与 npm SDK 发布版分别锁定，详见 `agent-core/pi-source.lock.json`。
- [Pi extensions](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/extensions.md)：后续受控定制的参考；本版不隐式加载用户扩展或技能。

`SpoddyCoder/clonepi` 是树莓派磁盘克隆工具，与个人 AI Agent 无关；项目中明确使用的是 Pi coding agent，避免名称歧义。

## 产品交互参考

- [Today](https://today.ai/) 和 [产品说明](https://today.ai/articles/blog/what-is-today)：借鉴短简报、可编辑记忆、只在高价值时主动出现，以及外部动作确认后执行。
- [Google Antigravity 总览](https://antigravity.google/docs/overview/) 与 [功能说明](https://antigravity.google/docs/features/)：借鉴异步任务、计划任务、子 Agent、产物审阅和权限策略。

这些网站的产品文案是设计参考，不是本项目的性能或安全证明；Another You 保持单用户、本地优先和默认不联网。

## 工程参考

- 本机 Zisla 的 `swift-tests.yml`、`web-ci.yml`：采用最小权限、并发取消、独立构建检查和始终清理产物的模式；未复制与本项目无关的发布、项目自动化和跨平台流程。
- 开发使用 development-workflow、agent-reach、octocat 及 UI 技能组织实现和核验。它们属于开发工具，不会作为隐式权限或第三方提示词自动装入用户的助手运行时。

第三方代码通过包管理器或独立源码缓存使用，保留各自许可证；参考站的品牌资产未纳入应用。
