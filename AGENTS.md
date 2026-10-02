# Another You

- 开发、修复、测试和评审使用 [another-you-app-development](skills/another-you-app-development/SKILL.md)。准备或执行 macOS 发版、Sparkle 更新与 Homebrew 分发时使用 [another-you-release](skills/another-you-release/SKILL.md)。
- 先阅读相关实现，复用现有 SwiftUI、JSONL 与 Pi 模式，做最小修改；保留用户和并行任务的改动。中文沟通，产品界面避免重复说明和调试信息。
- GitHub 用于源码、Issue 和 PR；Gitee 用于镜像与版本分发。GitHub Project 保留现有视图和字段，不创建任务卡。
- 配置、签名密钥、应用数据和测试产物不入库。构建、测试、实际窗口交互、真实升级和线上发布分别验证，不相互替代。
- 清理本次测试进程及临时产物，保留用户正在运行的应用与个人数据；`make clean` 会停止 `dist/dev` 实例，不能无条件执行。
