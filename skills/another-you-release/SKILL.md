---
name: another-you-release
description: 准备、执行或验证 Another You 的 macOS 发布、Sparkle 自动下载和自动安装渠道、GitHub/Gitee 发布镜像及 Homebrew cask。依据项目发布脚本生成 arm64/x86_64 签名包和双端 feed，核验真实升级与 Brew 安装；普通开发不自动触发远端发布。
---

# Another You 发布

在 Another You 仓库根执行。先读[发布指南](../../docs/releasing.zh-CN.md)、[发布配置](../../release/config.json) 和 [scripts/release.py](../../scripts/release.py)；实际参数以当前脚本 `--help` 为准。全局 Skill 软链只用于发现，命令应操作当前指定 checkout。

## 范围与发布身份

- 用户要求发版后，沿用本次会话已有授权完成构建、上传和验证，不重复索要发布确认。仅开发、编写 Skill 或准备本地包，不代表已授权远端发布、推送 tap 或改变仓库可见性。
- GitHub 承载开发、Issue/PR 和主发布，Gitee 承载镜像；不为发版新建 GitHub Project 任务卡。匿名可访问的 Release、feed 与 ZIP 必须实际验证，不能从仓库已公开推断附件可下载。
- 当前发布工具支持 `arm64` 与 `x86_64` 两套独立 ZIP，没有 universal 打包路径。每套都内置相同架构的官方 Node、生产依赖和 Sparkle，不能把单架构包称为 Universal。
- 使用同一已提交源码、同一版本和递增构建号制作两套包。先核对已有 tag、Release 与 feed 的版本/构建号。`preflight` 通过 `clean_source_commit()` 强制工作区干净，拒绝版本化修改及未忽略的新文件；打包结束再次检查源码仍干净、提交未变，manifest 的 `sourceCommit` 记录该输入提交。
- 已发布的版本包不可静默替换成不同构建。失败时先确认哪些远端步骤已生效，复用同一份已验证产物恢复；若必须修改内容，推进版本/构建号再发布。

## 签名与环境

| 配置 | 用途 |
| --- | --- |
| `SPARKLE_BIN` | 与项目 Sparkle 版本匹配的 `generate_appcast`、`sign_update` 所在绝对目录。 |
| `SPARKLE_ED_KEY_FILE` | Another You 专用更新私钥文件；普通文件，权限 `600`，必须匹配配置的 `publicEDKey`。 |
| `CODE_SIGN_IDENTITY` | 稳定代码签名证书身份；正式包拒绝 ad-hoc `-`。 |
| `CODE_SIGN_KEYCHAIN` | 可选的签名钥匙串。 |
| `ANOTHER_YOU_NODE` | 目标架构的自包含官方 macOS Node，版本至少 22.19；Intel 与 ARM 分别选择对应文件。 |
| `ANOTHER_YOU_NODE_LICENSE` | 可选的 Node 许可证路径；默认取官方发行包根目录 `LICENSE`。内置 Node 时许可证必须存在且非空。 |
| `NOTARYTOOL_PROFILE` | 可选的已配置公证 profile；仅在 Developer ID 签名时使用。 |

Sparkle Ed25519 更新签名与 macOS 代码签名各自独立。不能借用 Zshell/Zisla 的更新私钥、公钥或配置来通过检查；已有 Another You 密钥必须复用，不能因失败静默轮换。首次初始化仅在用户已授权的签名设置范围内执行，私钥放仓库外并保护备份。不要打印私钥、凭据或钥匙串密码。

每次发版使用用户当次提供的签名材料路径，按需设置 `SPARKLE_ED_KEY_FILE` 和 `CODE_SIGN_KEYCHAIN`，不自动沿用历史路径。不要把私人路径写入 Skill、README 或仓库文件。私钥与 `.p12` 备份保存在仓库外的独立目录，目录权限 `700`、文件权限 `600`；迁移时保持已有签名身份与发布公钥不变。

稳定自签名证书不等于 Developer ID，也不等于 Apple 公证。按 manifest 与实际 `codesign`、公证结果说明分发状态。没有 `NOTARYTOOL_PROFILE` 时不能宣称已公证。

发布包必须包含 `Contents/Resources/runtime/LICENSE` 和 `Contents/Resources/ThirdParty/Sparkle-LICENSE`；后者由本次官方 SwiftPM artifact 的 LICENSE 复制。不要用空文件或其他项目的许可证绕过验证。

`release/config.json` 使用 `schemaVersion`、`repository`、`homepage`、`downloadURLTemplate`、`feedURLTemplate`、`fallbackDownloadURLTemplate`、`fallbackFeedURLTemplate`、`publicEDKey`。两个 fallback 字段成对配置。URL 模板支持 `{version}`、`{arch}`、`{filename}`，必须区分架构；先核对配置实际解析值，不把未配置公钥或示例地址带入正式包。

## 本地构建与核验

下面大写值均为本次已确认参数，先赋值再执行；目录必须尚不存在。`--config` 放在子命令前。

```sh
python3 scripts/release.py --config release/config.json preflight \
  --version "$RELEASE_VERSION" --build "$RELEASE_BUILD" --arch arm64
```

对每个架构分别运行 preflight 与 package。以下是 ARM 示例；Intel 使用 `--arch x86_64`、对应 Node 和独立输出目录：

```sh
python3 scripts/release.py --config release/config.json package \
  --version "$RELEASE_VERSION" --build "$RELEASE_BUILD" --arch arm64 \
  --output "$RELEASE_ARM_DIR"
python3 scripts/release.py --config release/config.json verify \
  --manifest "$RELEASE_ARM_DIR/manifest.json"
```

每个输出目录包含 `another-you-v{version}-macOS-{arch}.zip`、同名 `.sha256`、`appcast-{arch}.xml`、`appcast-fallback-{arch}.xml` 与 `manifest.json`。备用 feed 仅在配置镜像时生成。manifest 的 `appcast` / `fallbackAppcast` 分别记录两份 feed。

核验覆盖 ZIP/SHA-256、完整 feed 与 enclosure 的 Ed25519 签名、版本/构建号、目标架构、内置 Node、Sparkle installer/XPC、稳定 designated requirement 及 `@rpath`。每个 Mach-O 都需匹配目标架构。不能只检查存在 `edSignature` 字段。

正式包需启用 `AnotherYouUpdatesEnabled`、`SURequireSignedFeed`、`SUVerifyUpdateBeforeExtraction`，其 `SUPublicEDKey`、`SUFeedURL` 和备用 feed 必须匹配配置。程序默认偏好与实际用户开关分开核对；不得为测试绕过验签或改用户密钥。

改发布工具时运行 `make test-release` 与 `bash -n scripts/build-app.sh`，并做受影响的真实构建。`make test-release` 汇总本地签名/元数据和双端发布流程测试；设置 `SPARKLE_BIN` 后包含官方 Sparkle 工具集成测试，未设置时该项明确跳过。

更新安装路径使用 `make test-updater-install`：在 macOS 的临时应用、本机 HTTP 通道和临时密钥中驱动真实安装器，覆盖自动安装、延后安装、仅下载、签名拒绝与备用源。测试自行清理，不替代正式 HTTPS 发布源、稳定签名身份和目标机器验收。发版不重复无关功能的开发验收，但必须验证本次包的启动、sidecar 与升级链路。

## 发布、Brew 与升级

使用独立 [scripts/publish-release.py](../../scripts/publish-release.py) 执行远端分发；默认只计划，`--publish` 才上传，`--verify` 只回读。正式发布和回读要求两套架构齐全。具体命令、镜像 feed 重命名、Brew 安装和升级验收见 [references/distribution.md](references/distribution.md)。本地 `release.py package` / `verify` 不执行远端上传，`cask` 不推送 tap。

只把本次真实验证过的结果写入 Release 和完成说明。分别报告本地包、双端匿名资产、目标架构启动、Brew 安装及真实 Sparkle 升级的结果；缺少旧版测试实例或目标架构机器时明确标注未验证。

结束后清理本次测试包、临时下载、构建目录、fixture 与测试进程，保留已交付产物、签名备份、用户运行的应用与个人数据。`make clean` 会停止开发实例，不作为发布收尾的无条件命令。
