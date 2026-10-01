# Another You Agent Core

[English](README.md) | **简体中文**

Another You 的 Node.js 22.19+ 运行时。通过 JSON Lines 与 Swift 通信，管理主动规则和本地状态，并使用官方 Pi SDK 调用模型。模型只生成可审阅文本，没有文件、Shell、网络浏览或发送消息工具。

## 开发运行时

从仓库根目录执行：

```bash
make deps
make check
make test-agent
```

直接运行 sidecar 时，进入 `agent-core`：

```bash
npm start -- --config "$HOME/Library/Application Support/AnotherYou/config.json"
```

每行输入一个 JSON 命令，例如 `{"op":"status"}`，最后输入 `{"op":"shutdown"}`。宿主需要直接消费 stdout 时，使用 [CLI 参考](../docs/cli-reference.zh-CN.md) 中的 Node 命令；npm 可能额外打印脚本启动信息。

Node 在运行时擦除 TypeScript，因此不生成 JavaScript 构建产物。`npm run check` 执行 TypeScript 类型检查。CLI 将协议事件写入 stdout，启动诊断写入 stderr。

配置缺失时使用回环端点和占位模型 `local-default`，填写真实模型名称前保持未配置状态。[config.example.json](config.example.json) 中的 `qwen3:8b` 仅为示例，需要单独安装模型或替换为服务中已有的名称。运行时不会安装模型或启动模型服务。

## 代码职责

| 文件 | 职责 |
| --- | --- |
| [src/cli.ts](src/cli.ts) | JSONL 输入、命令分发、模型请求并发和关闭 |
| [src/index.ts](src/index.ts) | 建议、用户决定、暂停状态、历史与默认规则 |
| [src/scheduler.ts](src/scheduler.ts) | 时间/事件/闲置匹配、冷却和去重 |
| [src/pi-adapter.ts](src/pi-adapter.ts) | Pi 会话、端点策略与模型请求 |
| [src/config.ts](src/config.ts) | 默认值、校验、配置加载和保存 |
| [src/state.ts](src/state.ts) | 状态持久化、内容保存策略和凭据遮盖 |
| [src/events.ts](src/events.ts) | 事件结构与 JSONL 编码 |

CLI 同时只处理一条模型请求。模型运行期间仍可查询状态、暂停或关闭；第二条模型请求会报错。每次请求最多运行 60 秒，不自动重试。每次请求创建独立 Pi 会话，不会自动携带聊天记忆。

## Pi 源码与 SDK

实际运行依赖为 `@earendil-works/pi-agent-core` 与 `@earendil-works/pi-ai`，均固定为 **0.99.2**。[package-lock.json](package-lock.json) 锁定完整 npm 依赖树，[pi-source.lock.json](pi-source.lock.json) 分别记录上游源码快照与 SDK 发布提交。

需要阅读锁定的上游源码时，从仓库根目录执行：

```bash
make pi-source
./agent-core/scripts/bootstrap-pi.sh --print
```

源码以 detached HEAD 检出到被忽略的 `agent-core/.cache/pi`，不会编入应用，也不会取代 npm SDK。锁定检查、SSH 传输和有意升级见 [来源说明](../docs/sources.zh-CN.md)。

适配器显式构建 Pi `Agent`，使用空工具列表和受限 HTTP fetch。不启动 Pi coding CLI，不加载用户 Pi 配置、扩展、技能或默认提供方凭据，也不配置遥测导出器。

## 验证

[运行时测试](test/runtime.test.ts) 通过本机 HTTP fixture 驱动真实 Pi SDK，覆盖无工具模型请求、主机限制、重定向拒绝、错误、隐私存储、凭据遮盖、用户决定、重启恢复、JSONL 子进程及慢请求期间的控制命令。[核心测试](test/core.test.ts) 覆盖配置与调度器行为。测试不需要真实 API 密钥或下载模型。

这些测试验证 fixture 下的行为，不能证明与所有真实模型服务兼容。配置服务后应提交实际请求，并单独记录结果。从仓库根目录运行 `make clean` 可清理已知构建和测试产物，依赖与 Pi 源码缓存会保留。

## 延伸阅读

- [配置参考](../docs/configuration.zh-CN.md)：端点策略、存储、默认值和环境变量。
- [CLI 与 JSONL 协议](../docs/cli-reference.zh-CN.md)：命令、事件、规则和建议状态。
- [架构](../docs/architecture.zh-CN.md)：Swift/运行时边界与数据流。
- [贡献指南](../CONTRIBUTING.zh-CN.md)：针对性检查与协作规则。
