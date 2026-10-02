# 发布配置 / Release configuration

[config.json](config.json) 仅保存 Another You 的公开发布元数据：仓库、主/备用下载源、更新源与 Ed25519 公钥。私钥、令牌和签名凭据保存在仓库外。

[config.json](config.json) contains only Another You's public release metadata: repository, primary/fallback downloads and feeds, and the Ed25519 public key. Keep private keys, tokens, and signing credentials outside the repository.

完整的打包、签名、更新、Homebrew 与验证流程见 / For packaging, signing, updates, Homebrew, and validation:

- [简体中文发布指南](../docs/releasing.zh-CN.md)
- [English release guide](../docs/releasing.md)
