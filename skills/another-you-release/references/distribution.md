# 双端分发与 Homebrew

本文件用于本地 manifest 验证通过后的发布执行和升级验收。配置与命令以仓库 [release/config.json](../../../release/config.json)、[scripts/release.py](../../../scripts/release.py)、[scripts/publish-release.py](../../../scripts/publish-release.py) 和[发布指南](../../../docs/releasing.zh-CN.md) 为准。

## 执行命令

发布工具先复用本地 manifest 验证，再处理远端。默认及 `--dry-run` 都只生成计划，不访问发布 API，不写 tap；可传单架构查看计划，但 `--publish` / `--verify` 要求 ARM 与 Intel 两套 manifest。两套必须版本、构建号、源码提交和发布身份一致。

```sh
python3 scripts/publish-release.py --dry-run --config release/config.json \
  --manifest "$RELEASE_ARM_DIR/manifest.json" \
  --manifest "$RELEASE_INTEL_DIR/manifest.json"
```

用户已授权本次发布时，准备 `GH_TOKEN` / `GITHUB_TOKEN` 或已有 `gh auth login`，以及 `GITEE_TOKEN` 环境变量；不要把 token 放命令行、日志或 Release 正文。准备描述用户可见变化及实际签名/公证状态的说明文件，然后执行：

```sh
python3 scripts/publish-release.py --publish --config release/config.json \
  --manifest "$RELEASE_ARM_DIR/manifest.json" \
  --manifest "$RELEASE_INTEL_DIR/manifest.json" --notes-file "$RELEASE_NOTES"
python3 scripts/publish-release.py --verify --config release/config.json \
  --manifest "$RELEASE_ARM_DIR/manifest.json" \
  --manifest "$RELEASE_INTEL_DIR/manifest.json"
```

发布不改变仓库可见性。已有 tag 必须指向 manifest 的源码提交，既有版本附件同名不同字节直接拒绝；同字节复用。工具检查当前稳定版本与构建号，拒绝降级。打包工具已通过 `clean_source_commit()` 在构建前后强制核验干净源码和固定提交，恢复发布时复用该提交产出的已验证 manifest 与附件。

## 发布顺序

1. 核对源码提交、版本、构建号、签名身份、两个架构 manifest 及既有远端资产；沿用本次授权的目标仓库和 tap。
2. 先确保 Gitee 永久 `update-release` 存在，再创建版本 Release。GitHub 新版本先保持 draft；Gitee 永久 feed Release 必须早于其版本 Release。
3. 将已验证 ZIP 与校验文件上传两站版本 Release，并通过 API 回读核对字节。随后上传各站版本 feed：GitHub 使用 `appcast-{arch}.xml`；Gitee 将 `appcast-fallback-{arch}.xml` 重命名为 `appcast-{arch}.xml`。两站 feed 各自引用本站 ZIP。
4. 通过 `publish_version()` 将 GitHub 版本公开，保持 `make_latest=false`。匿名下载两站版本 Release 的 ZIP、校验文件和 feed，与本地已签名产物逐字节核对；任何一项失败，都不推进 Gitee 永久 feed 或 GitHub latest。API 认证下载成功不能代替这一步。
5. 全部匿名版本附件验证通过后，先切换 Gitee `update-release` 的永久 feed，再将 GitHub 当前版本设为 latest。
6. 回读两站版本附件与稳定更新源，检查实际字节、SHA-256、版本、构建号，以及 GitHub latest 指向。网页返回 200 或登录页不能算下载成功。

发生上传、签名或访问失败时保留错误证据与已生效步骤，从对应步骤恢复，不反复创建版本、换密钥或覆盖历史包。远端未满足时报告准确阻塞，不能把本地成功写为正式发布完成。

Gitee 永久 feed 是唯一允许替换的附件：工具先上传带哈希后缀的暂存附件并验证，再替换正式名称；单个 feed 替换失败会尝试恢复旧字节。两站切换不是原子事务，失败时必须确认已生效步骤和暂存附件，不得声称已全部回滚。`--verify` 成功只证明远端分发字节与本地一致，不能证明客户端已完成安装重启。

## 生成与更新 Homebrew cask

两个架构的 manifest 必须具有相同版本、构建号、源码提交和发布身份。输出文件需为新路径：

```sh
python3 scripts/release.py --config release/config.json cask \
  --manifest "$RELEASE_ARM_DIR/manifest.json" \
  --manifest "$RELEASE_INTEL_DIR/manifest.json" \
  --output "$CASK_OUTPUT"
```

只传一个 manifest 会生成限制 CPU 架构的 cask，不能据此宣称支持另一架构。先检查生成文件的实际 ZIP URL、两种架构 SHA-256、`livecheck`、最低 macOS 与公证说明；哈希取已验证的发布字节，不填占位哈希，不因下载失败改用 `:no_check`。

发布到用户指定的 tap；当前 tap 位置、分支和发布方式应查实际仓库与会话授权，不复制其他应用的 tap 文件或假定已可 `brew install`。在 `publish-release.py --publish` 命令上显式增加 `--tap-path "$TAP_REPOSITORY"`，会在双端发布与回读成功后写入该仓库的 `Casks/another-you.rb`。已有不同的未提交内容、符号链接或发布期间发生的文件变化会导致拒绝覆盖；`--dry-run --tap-path` 只检查目标，不写入。

工具不提交、不推送 tap。完成授权的 tap 提交/PR/推送并验证远端后，才能给出可用安装命令。若仅需本地 cask 审核，使用上面的 `release.py cask` 命令，无须发布。

验证时用实际 tap-qualified token 替换 `$CASK_TOKEN`，运行所在 tap 适用的 `brew audit --cask` / `brew style` 检查，并在隔离测试环境执行：

```sh
brew install --cask "$CASK_TOKEN"
brew info --cask "$CASK_TOKEN"
brew upgrade --cask --greedy "$CASK_TOKEN"
```

若本机已经安装或正在运行用户的 Another You，先采用独立测试账户、VM 或一次性环境，不能为了验证覆盖个人安装。测试首次启动、Node sidecar 自包含、版本/架构、设置保留与后续 Sparkle 升级。无真实安装环境时只报告 cask 静态验证通过。

`auto_updates true` 表示应用可由 Sparkle 自更新，Homebrew 的常规批量升级可能跳过它；需要 Brew 强制纳入检查时使用 `--greedy`。不能把 `brew upgrade` 与应用内自动安装描述为同一个机制。常规卸载不应删除个人数据；不要在验收中对用户安装执行 `brew uninstall --zap`。

## 自动下载与自动安装验收

使用旧构建号的独立、稳定签名 `.app`，测试数据与偏好隔离；生产用户配置和运行实例不得作为一次性 fixture。

- 自动检查、自动下载、自动安装的开关分别可见并跨重启持久化；关闭前置开关后的依赖状态与实现一致。单独开启自动下载，不得误报为立即自动重启安装。
- 在模型生成进行时收到更新，草稿和状态保持完整；允许安装后走正常退出路径，sidecar 保存结束，再由 Sparkle 替换并重启。重启后核对实际运行的新版本与构建号。
- 首选 feed 失败、首选 ZIP 下载失败时能使用备用源；无更新、用户取消或验签失败不能被当作成功。核对重试边界和实际实现，不能无限重试或降级验签。
- 两套架构分别检查下载包与运行进程架构。ARM 上成功构建 Intel 包不等于在 Intel Mac 上运行通过。
- 检查真实 HTTPS 签名 feed → 下载 → 验签 → 替换 → 重启全链路。测试驱动、fixture、本地验签、UI 开关或 CI 通过，都不能替代真实升级结果。

记录起止版本/构建号、架构、源站、设置组合和结果。只清理本次测试实例及临时文件，不删除用户的应用支持目录、默认偏好或签名备份。
