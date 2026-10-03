# 打包与发布现状

[English](releasing.md) | **简体中文**

Another You 当前为 **0.1.0 开发预览**，源码已公开。自动更新、双架构打包、GitHub/Gitee 发布与 Homebrew cask 生成工具已实现，首个公开安装包和 cask 尚未发布。默认开发包使用 ad-hoc 签名并禁用在线更新；正式包需要项目独立的签名配置。

## 构建开发应用

需要完整 Xcode 27+、macOS 27+ SDK 和 Python 3；默认打包会准备官方 Node 与 npm，开发检查另需 Node.js 22.19+ 和 npm。应用最低运行版本仍为 macOS 14。从仓库根目录执行：

```bash
make build-package
```

[scripts/build-app.sh](../scripts/build-app.sh) 使用临时 scratch 目录，默认以 Release 模式构建 Swift 可执行文件，复制 sidecar 源码、锁定的 npm 生产依赖和 Sparkle 2.9.4，写入 `Info.plist`，进行 ad-hoc 签名并验证应用包；退出时清理临时构建目录。

构建使用 `DEVELOPER_DIR` 或 `xcode-select` 选定的完整 Xcode；版本过低或仅安装 Command Line Tools 时在编译前报错。可执行文件的 `LC_BUILD_VERSION` 记录所选 SDK，打包时会核对该字段与当前 SDK 一致。最低运行版本 macOS 14 与链接 SDK 版本分别记录。

默认输出为 `dist/macos/Another You.app`，脚本拒绝覆盖已有应用。要保留之前的构建，请选择新目录：

```bash
OUTPUT_DIRECTORY="$PWD/dist/review-build" make build-package
```

打包会使用官方 Node 发行包内的 npm 安装锁定的生产依赖，不读取个人 `.npmrc`，也不复制开发者配置、认证或浏览器资料。首次构建可能访问 Node、npm 与 Playwright 的公共下载源；开发类型检查和测试仍需先运行 `make deps`。

`make build-package` 固定使用 Release 配置，但默认仍为 ad-hoc 签名且禁用在线更新；正式签名、更新元数据与归档见下方正式打包流程。直接调用脚本时可设置 `CONFIGURATION=debug` 或 `release`，默认 `release`。

## Node 与架构

| 变量 | 默认值 | 含义 |
| --- | --- | --- |
| `OUTPUT_DIRECTORY` | 仓库内 `dist/macos` | 包含 `Another You.app` 的目标目录。 |
| `BUNDLE_NODE` | `1` | `1` 内置 Node、npm 与后台浏览器；`0` 仅用于依赖本机环境的源码开发包。 |
| `ANOTHER_YOU_NODE` | 未设置，自动准备锁定的官方发行包 | 可显式选择完整官方发行目录里的 `bin/node`。 |
| `ANOTHER_YOU_RUNTIME_CACHE` | `agent-core/.cache/runtime` | 公共运行依赖下载缓存，使用前重新校验 SHA256。 |

默认应用包含 Node 22.23.3、npm、Pi 的锁定生产依赖，以及与 Playwright 1.63.0 匹配的 Chromium Headless Shell 153.0.8010.12。版本、下载地址和两个架构的 SHA256 由 [运行依赖锁](../scripts/runtime-dependencies.json) 与 [准备脚本](../scripts/prepare-runtime.py) 固定；构建失败会清理暂存解压目录。应用内的 `runtime/manifest.json` 记录实际打包版本。

已有官方 Node 发行目录时可以显式复用：

```bash
BUNDLE_NODE=1 \
ANOTHER_YOU_NODE="/absolute/path/to/official-node/bin/node" \
OUTPUT_DIRECTORY="$PWD/dist/bundled-review" \
  make build-package
```

该目录必须包含 `bin/node`、`include/node/node_version.h`、`lib/node_modules/npm` 及其许可证；单个 binary 加许可证不构成完整覆盖。Node 的 `LICENSE` 默认从发行目录读取，也可用 `ANOTHER_YOU_NODE_LICENSE` 指定。依赖外部动态库的 Homebrew Node 不能直接内置。浏览器仍按锁定版本准备；Node、npm、Chromium、Pi 与 Sparkle 的许可证随包保存，Pi 许可来源的 SDK 提交与摘要也随包记录。

完整应用优先使用包内 Node 与浏览器，忽略开发环境的运行文件覆盖；包内运行依赖缺失时会报错。Node 子进程使用内置运行时目录作为 `PATH` 首项，并移除 `NODE_OPTIONS`、`NODE_PATH` 与 `DYLD_*`。`BUNDLE_NODE=0` 才保留本机 Node 和已安装浏览器回退，不能将这种开发包直接分发。

`BUILD_ARCH=arm64` 或 `x86_64` 选择目标架构，默认为构建机架构。Swift、Node、浏览器与 Sparkle 必须匹配目标架构；交叉构建另用构建机架构的官方 Node 安装依赖，不要求执行目标架构 Node。不生成 universal 包。Xcode、Swift 与 Python 是构建工具，用户运行完整应用不需要安装它们。模型权重不打包，模型账户或服务由用户在应用模型设置中配置。

## 本地开发生命周期

| 命令 | 行为 |
| --- | --- |
| `make build` | 在 `macos/AnotherYou/.build` 生成 debug Swift 可执行文件，不生成 `.app`。 |
| `make run` | 构建 Debug 应用，并在 `dist/dev/Another You.app` 启动本工作区管理的实例。 |
| `make update` | 与 `make run` 相同，按本地代码重建/重启，不执行 Git fetch 或 pull。 |
| `make stop` | 停止受管理的开发实例及其 sidecar。 |
| `make build-package` | 以 Release 配置生成独立 `.app`，不启动它。 |
| `make clean` | 停止受管理实例并删除已知构建/测试产物。 |

`run` 与 `update` 固定使用 Debug 配置并关闭在线更新，使用固定开发目录，不受 `OUTPUT_DIRECTORY` 或 `CONFIGURATION` 影响。新应用构建完成后，才停止旧的受管理实例。[dev-service.sh](../scripts/dev-service.sh) 记录 PID、进程启动时间和可执行命令，过期记录不会成为停止其他进程的依据。日志位于 `dist/dev/another-you.log`。

Debug 应用在 macOS 中显示为 **Another You Debug**，Bundle ID 为 `com.anotheryou.mac.debug`，默认数据目录为 `~/Library/Application Support/AnotherYouDebug/`；Release 保持 `com.anotheryou.mac` 与 `AnotherYou/`。`ANOTHER_YOU_DATA_DIR` 仍优先于默认目录。两种配置都记录 `Info.plist` 中的 `AnotherYouBuildConfiguration`，`.app` 文件名保持 `Another You.app`。Debug 同时输出 `Another You.app.dSYM`，保留临时 scratch 清理后的行级调试信息；`update` 同步替换应用与符号，`clean` 一并清理。

`make clean` 清理受管理应用/日志、默认 `dist/macos/Another You.app` 及其 `.dSYM`、Swift `.build`、Agent coverage 与开发临时文件；保留 `agent-core/node_modules`、`agent-core/.cache/pi`、个人应用数据和自定义输出目录的应用包。自行创建的临时或自定义产物，检查后另行清理。

## 验证

提出打包改动前：

```bash
make deps
make check
make test
make build-package
codesign --verify --deep --strict "dist/macos/Another You.app"
plutil -lint "dist/macos/Another You.app/Contents/Info.plist"
node scripts/test-bundled-runtime.mjs "dist/macos/Another You.app"
```

`test-bundled-runtime.mjs` 检查许可证、动态链接、代码签名，在空临时 `HOME` 和最小 `PATH` 下启动包内 sidecar、npm、文件/命令行/网络工具与真实内置浏览器，使用本地网页完成输入、点击和截图，退出时清理临时资料。Pi 的本地开销可用 `node scripts/benchmark-pi.mjs agent-core /absolute/path/to/node` 重复测量；它使用 7 个独立进程与每次 100 个文件工具循环，不包含网络模型延迟。此基准不能证明全部模型、扩展或完整 Swift 替代实现的兼容性。

已有应用时应选用新输出目录，并同步调整检查路径。独立检查应用能否打开、定位 sidecar 与 Node、准确报告模型配置、处理真实模型请求、重启后恢复决定，以及正常退出。通知检查需要应用包、用户主动开启和 macOS 授权。每个计划支持的目标架构都应实际验证，不根据构建机推断兼容性。

验证完成后运行 `make clean`，检查 `git status --short` 和 `git diff --check`。自定义打包输出和临时截图需另行清理，不应把用户应用数据当作构建产物删除。

## CI 产物

现有 [CI 工作流](../.github/workflows/ci.yml) 在向 `main` 推送、Pull Request 和手动触发时运行，检查 Agent、Swift 与 sidecar 集成、开发生命周期脚本、官网 JavaScript 和 Shell 语法。Swift 任务使用 GitHub 的 `xcode-27` 预览 runner，校验 Xcode 与链接 SDK，以 `BUNDLE_NODE=1` 构建并验证应用包，再用临时配置执行 JSONL status/shutdown 冒烟检查。

该任务归档 `Another-You-macOS.zip`，上传名为 `Another-You-macOS-development-${{ runner.arch }}` 的 Actions 产物，保留七天。这是特定架构的开发产物，访问受仓库权限和保留期限制，不是 GitHub Release。工作流不验证真实模型推理、视觉质量或通知送达；是否通过应查看实际运行，不能把本文当作最新 CI 已通过的证据。

## 自动更新

设置中的三个开关分别控制自动检查、自动下载和自动安装，初始均关闭。自动安装依赖前两项；关闭自动检查会关闭下载和安装。只启用下载时，由 Sparkle 在正常退出时安装；启用自动安装后，等待会话生成、运行卡片和待确认操作结束，再安装并重启。手工检查不要求启用自动检查。

更新使用 HTTPS、Ed25519 完整 feed 签名与包签名，并在解压前校验。主 feed 或下载失败时尝试一次配置的备用源；用户取消、无新版本或安装失败不触发镜像重试。应用更新访问 GitHub/Gitee，不受模型端点网络策略控制。开发包以及直接 `swift run` 禁用更新，`make update` 仍只是按本地代码重建。

## 签名与正式打包

发布配置在 [release/config.json](../release/config.json)，目前公钥为 `null`，正式 preflight 会拒绝继续。第一次发布前准备 Another You 独立的 Ed25519 密钥和稳定代码签名证书，将公钥写入配置，私钥保存在仓库外并备份。不要复用其他应用的更新身份。两个架构应来自同一干净提交，版本使用 `X.Y.Z`，构建号必须比已发布版本递增。

| 变量 | 用途 |
| --- | --- |
| `SPARKLE_BIN` | Sparkle 2.9.4 的 `generate_appcast`、`sign_update` 所在绝对目录。 |
| `SPARKLE_ED_KEY_FILE` | 权限 `600` 的更新私钥文件，必须与配置公钥匹配。 |
| `CODE_SIGN_IDENTITY` | 稳定签名身份，正式打包拒绝 ad-hoc `-`。 |
| `CODE_SIGN_KEYCHAIN` | 可选钥匙串路径。 |
| `ANOTHER_YOU_NODE` | 目标架构的官方自包含 Node；正式包必须内置。 |
| `ANOTHER_YOU_NODE_LICENSE` | Node 发行目录不含相邻许可证时，可显式指定许可证路径；内置 Node 必须附带许可证。 |
| `NOTARYTOOL_PROFILE` | 可选公证 profile，需要 Developer ID Application 证书。 |

稳定自签名证书不等于 Developer ID 或 Apple 公证。manifest 分别记录实际状态。首次初始化密钥时可用官方 `generate_keys --account another-you`；导出时使用同一 account，先设置 `umask 077`，不要打印或提交私钥。

以下示例需要先设置上述环境与本次发布参数；`--config` 在子命令前，输出目录必须尚不存在：

```bash
python3 scripts/release.py --config release/config.json preflight \
  --version "$RELEASE_VERSION" --build "$RELEASE_BUILD" --arch arm64
python3 scripts/release.py --config release/config.json package \
  --version "$RELEASE_VERSION" --build "$RELEASE_BUILD" --arch arm64 \
  --output "$RELEASE_ARM_DIR"
python3 scripts/release.py --config release/config.json verify \
  --manifest "$RELEASE_ARM_DIR/manifest.json"
```

Intel 使用对应 Node、`--arch x86_64` 与独立输出目录。每个目录含版本 ZIP、SHA256、主/备用 appcast 和 manifest。工具验证版本、架构、框架、rpath、代码签名、Ed25519 签名及哈希。普通开发打包还可用 `APP_VERSION`、`APP_BUILD` 和 `BUILD_ARCH` 覆盖默认 `0.1.0`、`1` 和本机架构。

## 双端发布与 Homebrew

[发布 Skill](../skills/another-you-release/SKILL.md) 和[分发流程](../skills/another-you-release/references/distribution.md) 提供当前上传命令与恢复步骤。先检查本地 manifest，再预览发布计划。显式发布时，先上传并核验两站版本附件，再切换稳定 feed。Gitee 使用固定 `update-release` 存放备用 feed；其 enclosure 指向 Gitee 的版本包。同版本附件不允许被不同哈希覆盖。

两个架构产物核验后生成 cask：

```bash
python3 scripts/release.py --config release/config.json cask \
  --manifest "$RELEASE_ARM_DIR/manifest.json" \
  --manifest "$RELEASE_INTEL_DIR/manifest.json" \
  --output "$CASK_OUTPUT"
```

cask 使用真实产物的 SHA256、架构地址、Sparkle livecheck 和 `auto_updates true`，生成操作不推送 tap。只有公开包与 tap 更新均完成并验证后，才可使用 `brew install --cask wzz6423/tap/another-you`；当前该 cask 尚未上线。之后可用 `brew upgrade --cask --greedy wzz6423/tap/another-you` 将具有自更新能力的应用纳入 Brew 升级。Brew 安装的应用保留同一套应用内更新设置。

`make test-updater-install` 在临时应用、临时密钥与本机 HTTP 通道中运行真实 Sparkle 升级，覆盖下载、自动重启、延后安装和签名拒绝，并自行清理。正式客户端入口仍要求 HTTPS。

发布前还需实际验证各目标架构启动、旧版到新版替换、下载后延迟安装、签名拒绝，以及 Brew 安装/升级。测试通过、包生成、上传成功和用户机器可安装是不同结论，应分别记录。`make test-release` 使用临时 fixture 验证发布工具；设置 `SPARKLE_BIN` 时还运行真实 Sparkle 签名工具测试。

开发 Issue 和 Pull Request 统一在 [GitHub](https://github.com/wzz6423/another-you) 管理。[Gitee](https://gitee.com/wzz6423/another-you) 仅用于镜像访问与版本分发，不接收 Issue 或 Pull Request。
