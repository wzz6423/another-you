# Another You

一个只面向 macOS 的私有化个人 AI 助手。在合适的时间提出下一步，让你决定生成草稿、稍后提醒或忽略。

SwiftUI 负责原生窗口、菜单栏和设置，Node sidecar 负责主动调度、状态持久化与 Pi Agent SDK。本版以本机模型为默认入口，属于可运行的开发预览。

## 本地运行

需要 macOS 14+、Swift 6 工具链、Node 22.19+，以及提供 OpenAI 兼容 API 的本机模型服务。

```bash
(cd agent-core && npm ci)
ANOTHER_YOU_AGENT_ROOT="$PWD/agent-core" \
  swift run --package-path macos/AnotherYou AnotherYou
```

首次打开后，在设置里填写模型地址和已安装的模型名称。以 Ollama 为例，地址是 `http://127.0.0.1:11434/v1`，模型名须与 `ollama list` 一致。应用不会自动下载模型，服务不可用时会显示错误。

```bash
# 示例：需要先自行安装 Ollama，然后选择一个适合本机的模型
ollama pull qwen3:4b
```

开发环境可通过 `ANOTHER_YOU_NODE` 指定 Node 可执行文件。应用数据保存于 `~/Library/Application Support/AnotherYou/`；配置为 `config.json`，建议及活动记录为 `state.json`。

## 当前能力

- 从启动事件、每日时间和实际闲置时长产生主动建议，带来源说明、冷却与去重。
- 生成草稿、稍后提醒、忽略和暂停主动提醒；建议状态保存在本机。
- 通过真实 stdin/stdout JSONL 协议连接 Swift 与 Node，模型请求由官方 Pi SDK 执行。
- 默认只连接本机回环地址；远程私有模型需在配置中明确授权主机和网络访问。
- 官网预览展示建议交互和本地启动步骤，不包含追踪脚本或远程提交表单。

尚未接入 Calendar、Mail、Notes 或屏幕内容。当前模型没有文件、Shell、发送消息等工具；“生成草稿”不会对外执行动作。规则产生建议与模型推理是两条明确区分的路径，模型缺失不会伪装为成功。

## 开发应用与官网

```bash
# 生成本机开发 .app；依赖本机 Node，不可直接分发
./scripts/build-app.sh
open "dist/macos/Another You.app"

# 使用 nodejs.org 官方独立二进制内置 Node
BUNDLE_NODE=1 ANOTHER_YOU_NODE=/path/to/official-node/bin/node \
  OUTPUT_DIRECTORY=/path/to/new-output ./scripts/build-app.sh

# 官网本地预览
python3 -m http.server 4173 --bind 127.0.0.1 --directory website
```

打包脚本只生成当前架构的 ad-hoc 签名开发应用，并拒绝覆盖已有输出。CI 验证通过后保留开发 ZIP 产物 7 天。尚未做 Developer ID 签名、公证、正式下载或自动更新。Gitee 的 GitHub 镜像由仓库所有者配置。

## 项目结构

| 路径 | 职责 |
| --- | --- |
| `macos/AnotherYou` | SwiftUI、菜单栏、设置、sidecar 客户端 |
| `agent-core` | 调度、持久化、模型隐私策略、Pi SDK |
| `website` | 官网静态页面及建议交互演示 |
| `scripts/build-app.sh` | macOS 开发应用打包 |
| `.github/workflows/ci.yml` | Swift、Agent、官网与打包检查 |

## 验证

```bash
(cd agent-core && npm ci)
npm run check --prefix agent-core
npm test --prefix agent-core
swift test --package-path macos/AnotherYou
bash -n scripts/build-app.sh
```

测试中的模型服务使用本地 HTTP fixture，不代表真实模型的回答质量。CI 参考 Zisla 的最小权限、并发取消、分模块验证和产物清理，并检查 `.app` 结构、签名及内置 sidecar 的运行。

## 上游与定制

使用 MIT 许可的 [Pi](https://github.com/earendil-works/pi)。最新源码提交和生产 SDK 版本分别锁定在 [`agent-core/pi-source.lock.json`](agent-core/pi-source.lock.json)；生产依赖由 `package-lock.json` 固定。定制保留在本项目调度和适配层，不把第三方源码复制进主仓库。

```bash
# 可选：拉取锁定的上游源码以供研究和定制
./agent-core/scripts/bootstrap-pi.sh
```

架构和隐私边界见 [`docs/architecture.md`](docs/architecture.md)，来源与采用方式见 [`docs/sources.md`](docs/sources.md)。
