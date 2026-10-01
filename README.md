# Another You

Another You 是一个只面向 macOS 的私有化个人 AI 助手原型。它以“主动提醒、可审阅、可撤回”为默认交互：助手在合适的时间提出少量建议，用户确认后才执行外部动作。

## 当前形态

- `macos/AnotherYou`：SwiftUI 原生界面和本地 mock，展示主动卡片、时间线、执行/稍后/忽略动作。
- `agent-core`：主动触发、冷却去重、隐私配置和 Pi 运行时接入边界。
- `.github/workflows/ci.yml`：macOS Swift 构建/测试与 Agent 核心测试。

项目仍处于 MVP 阶段，当前不读取屏幕、不连接邮件/日历，也不会在后台发送消息或执行不可逆动作。

## 快速开始

```bash
git clone https://github.com/wzz6423/another-you.git
cd another-you

# SwiftUI 界面
swift build --package-path macos/AnotherYou
swift test --package-path macos/AnotherYou

# Agent 核心
./agent-core/scripts/bootstrap-pi.sh
cd agent-core
npm ci
npm test
```

首次运行 Pi 接入前，先阅读 `agent-core/README.md` 和 `agent-core/config.example.json`，所有密钥都应放在本机 Keychain 或环境变量中，不要写入仓库。

## 私有化原则

1. 数据默认留在本机，外部连接器按项启用并可撤销。
2. 主动建议必须有来源、原因、风险级别和冷却窗口。
3. 发送邮件、修改日历、执行命令等外部动作始终需要显式确认。
4. Pi 上游通过脚本按锁定 commit 拉取，定制逻辑放在本项目扩展层，便于升级和回滚。

## 上游说明

底层 Agent 使用 [earendil-works/pi](https://github.com/earendil-works/pi) 的可扩展运行时。当前锁定版本和许可证见 `agent-core/upstream.json`；Pi 项目采用 MIT 许可证。仓库不把上游源码直接复制进主仓库，bootstrap 脚本会按锁定 commit 拉取到被忽略的本地目录。

## 开发状态

这是一个可运行的本地骨架，后续优先级是：菜单栏入口与系统通知、事件采集权限、Keychain 密钥存储、连接器审批、长期记忆编辑器和真实 Pi session 流式输出。
