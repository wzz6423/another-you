# Another You Agent Core

这是 macOS Swift UI 使用的本地优先主动式 Agent 核心。运行时使用 Node 22.19+ 的原生 TypeScript 类型擦除，不把 Pi 第三方源码复制进本仓库。

## Pi 来源与私有化边界

`pi-source.lock.json` 锁定了公开 Pi Agent Harness 的来源、分支和完整提交 SHA。当前来源是 `https://github.com/earendil-works/pi`（原 `badlogic/pi-mono` 路径已重定向），许可为 MIT。执行以下命令会把源码放在被 `.gitignore` 忽略的缓存目录，并以 detached HEAD 检查 SHA：

```bash
./scripts/bootstrap-pi.sh fetch
./scripts/bootstrap-pi.sh --check
./scripts/bootstrap-pi.sh --refresh
```

`--refresh` 是有意改变锁定版本的操作，完成后应审阅 `pi-source.lock.json`。核心通过 `src/pi-adapter.ts` 的窄接口接入 Pi，宿主可以自行选择子进程、SDK 或私有补丁层。

## 配置

复制 `config.example.json` 后通过 `--config` 指定。配置包括本地数据目录、模型提供方、工具开关、隐私策略和调度默认值。API 密钥不会被配置模型接受，只能通过 `model.apiKeyEnv` 引用环境变量；`strict-local` 会强制关闭网络工具。

## Swift JSON Lines 接口

启动：

```bash
npm start -- --config "$HOME/Library/Application Support/AnotherYou/config.json"
```

标准输入每行一条命令，标准输出每行一个 `AgentEvent`：

```json
{"op":"addRule","rule":{"id":"morning","type":"time","at":"09:00","title":"开始一天","message":"整理今天最重要的三件事","cooldownMs":3600000}}
{"op":"signal","signal":{"type":"event","name":"focus-ended","payload":{"minutes":50}}}
{"op":"tick","now":"2026-10-01T09:00:00+08:00","idleForMs":0}
{"op":"status"}
{"op":"shutdown"}
```

触发后会输出 `kind: "proactive.suggestion"` 的统一事件，字段包含规则、触发类型、上下文和去重键。`time`、`event`、`idle` 三类规则都经过去重窗口和冷却时间；Swift 层只需订阅 stdout 并将建议呈现给用户。

## 验证

```bash
npm test
npm run check
```

测试使用 Node 内置测试运行器，不生成 `.build`、二进制或持久化临时文件。
