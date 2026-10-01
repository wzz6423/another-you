# 公开来源与采用边界

## 底层 Agent

- [Pi coding agent](https://github.com/earendil-works/pi)：当前官方上游，MIT；本项目通过 `agent-core/pi-source.lock.json` 锁定完整 commit，并由 `scripts/bootstrap-pi.sh` 拉取到忽略目录。
- [Pi CLI integration](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/cli-integration.md)：采用本地 sidecar + JSONL/RPC 的集成方向，避免把 Node 运行时移植到 Swift。
- [Pi extensions](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/extensions.md)：后续定制优先使用扩展、技能和提示词包；只有需要改品牌或默认配置时才评估 fork。

`SpoddyCoder/clonepi` 是树莓派磁盘克隆工具，与个人 AI Agent 无关；项目中明确使用的是 Pi coding agent，避免名称歧义。

## 产品交互参考

- [Today](https://today.ai/) 和 [产品说明](https://today.ai/articles/blog/what-is-today)：借鉴短简报、可编辑记忆、只在高价值时主动出现，以及外部动作确认后执行。
- [Google Antigravity 总览](https://antigravity.google/docs/overview/) 与 [功能说明](https://antigravity.google/docs/features/)：借鉴异步任务、计划任务、子 Agent、产物审阅和权限策略。

这些网站的产品文案是设计参考，不是本项目的性能或安全证明；Another You 保持单用户、本地优先和默认不联网。
