# 打包与发布现状

[English](releasing.md) | **简体中文**

Another You 当前构建的是 **0.1.0 开发预览**。应用包使用 ad-hoc 签名，没有 Developer ID 签名或公证。尚无已确立的公开 Release、安装程序或自动更新渠道。构建、签名检查或 CI 产物成功，不代表已经适合正式分发。

## 构建开发应用

需要 macOS 14+、Swift 6、Node.js 22.19+ 和 npm。从仓库根目录执行：

```bash
make build-package
```

[scripts/build-app.sh](../scripts/build-app.sh) 使用临时 scratch 目录以 release 模式构建 Swift 可执行文件，复制 sidecar 源码与锁定的 npm 生产依赖，写入 `Info.plist`，进行 ad-hoc 签名并验证应用包；退出时清理临时构建目录。

默认输出为 `dist/macos/Another You.app`，脚本拒绝覆盖已有应用。要保留之前的构建，请选择新目录：

```bash
OUTPUT_DIRECTORY="$PWD/dist/review-build" make build-package
```

打包时会安装生产依赖；开发类型检查和测试仍需先运行 `make deps`。即使模型隐私为 `strict-local`，打包仍可能访问 npm，脚本使用 `PATH` 中的 `npm`。

## Node 与架构

| 变量 | 默认值 | 含义 |
| --- | --- | --- |
| `OUTPUT_DIRECTORY` | 仓库内 `dist/macos` | 包含 `Another You.app` 的目标目录。 |
| `BUNDLE_NODE` | `0` | `0` 使用本机 Node；`1` 将 Node 复制进应用。 |
| `ANOTHER_YOU_NODE` | 从 `PATH` 解析的 `node` | 校验的 Node 可执行文件，启用内置时也复制它。 |

`BUNDLE_NODE=0` 的应用仍要求目标 Mac 安装 Node.js 22.19+。要让开发应用自带运行时，提供已安装、自包含且架构与 Swift 构建匹配的官方 macOS Node：

```bash
BUNDLE_NODE=1 \
ANOTHER_YOU_NODE="/absolute/path/to/official-node/bin/node" \
OUTPUT_DIRECTORY="$PWD/dist/bundled-review" \
  make build-package
```

将 Node 路径替换为已有可执行文件。命令不会下载 Node 或模型。依赖外部动态库的 Homebrew Node 不允许直接内置，因为只复制可执行文件会遗漏这些库。相邻 Node `LICENSE` 存在时会一并复制，分发前仍需审阅第三方许可证。

脚本按当前 Swift 工具链选择的架构构建，没有 universal binary 或 Intel/Apple Silicon 发布矩阵。应用不包含模型权重，模型服务仍需单独准备。

## 本地开发生命周期

| 命令 | 行为 |
| --- | --- |
| `make build` | 在 `macos/AnotherYou/.build` 生成 debug Swift 可执行文件，不生成 `.app`。 |
| `make run` | 构建新应用，并在 `dist/dev/Another You.app` 启动本工作区管理的实例。 |
| `make update` | 与 `make run` 相同，按本地代码重建/重启，不执行 Git fetch 或 pull。 |
| `make stop` | 停止受管理的开发实例及其 sidecar。 |
| `make build-package` | 生成独立应用包，不启动它。 |
| `make clean` | 停止受管理实例并删除已知构建/测试产物。 |

`run` 与 `update` 使用固定开发目录，不受 `OUTPUT_DIRECTORY` 影响。新应用构建完成后，才停止旧的受管理实例。[dev-service.sh](../scripts/dev-service.sh) 记录 PID、进程启动时间和可执行命令，过期记录不会成为停止其他进程的依据。日志位于 `dist/dev/another-you.log`。

`make clean` 清理受管理应用/日志、默认 `dist/macos/Another You.app`、Swift `.build`、Agent coverage 与开发临时文件；保留 `agent-core/node_modules`、`agent-core/.cache/pi`、个人应用数据和自定义输出目录的应用包。自行创建的临时或自定义产物，检查后另行清理。

## 验证

提出打包改动前：

```bash
make deps
make check
make test
make build-package
codesign --verify --deep --strict "dist/macos/Another You.app"
plutil -lint "dist/macos/Another You.app/Contents/Info.plist"
```

已有应用时应选用新输出目录，并同步调整检查路径。独立检查应用能否打开、定位 sidecar 与 Node、准确报告模型配置、处理真实模型请求、重启后恢复决定，以及正常退出。通知检查需要应用包、用户主动开启和 macOS 授权。每个计划支持的目标架构都应实际验证，不根据构建机推断兼容性。

验证完成后运行 `make clean`，检查 `git status --short` 和 `git diff --check`。自定义打包输出和临时截图需另行清理，不应把用户应用数据当作构建产物删除。

## CI 产物

现有 [CI 工作流](../.github/workflows/ci.yml) 在向 `main` 推送、Pull Request 和手动触发时运行，检查 Agent、Swift 与 sidecar 集成、开发生命周期脚本、官网 JavaScript 和 Shell 语法。macOS 任务以 `BUNDLE_NODE=1` 构建，验证应用包，并用临时配置执行 JSONL status/shutdown 冒烟检查。

该任务归档 `Another-You-macOS.zip`，上传名为 `Another-You-macOS-development-${{ runner.arch }}` 的 Actions 产物，保留七天。这是特定架构的开发产物，访问受仓库权限和保留期限制，不是 GitHub Release。工作流不验证真实模型推理、视觉质量或通知送达；是否通过应查看实际运行，不能把本文当作最新 CI 已通过的证据。

## 正式分发的剩余工作

版本 `0.1.0`、构建号 `1` 和 bundle ID `com.anotheryou.mac` 当前由打包脚本写入。正式发布流程仍需补齐版本管理、支持架构构建、Developer ID 签名与公证、产物/许可证审阅，以及目标 Mac 上的安装/升级验证。自动更新尚未实现。

开发 Issue 和 Pull Request 统一在 [GitHub](https://github.com/wzz6423/another-you) 管理。[Gitee](https://gitee.com/wzz6423/another-you) 仅用于镜像访问与版本分发，不接收 Issue 或 Pull Request。GitHub 到 Gitee 的镜像由仓库所有者另行配置，本项目没有自动发布镜像流程。Zisla 的发布脚本和更新源不适用于 Another You。
