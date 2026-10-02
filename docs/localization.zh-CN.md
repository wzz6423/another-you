# 界面语言

[English](localization.md) | **简体中文**

macOS 应用与官网支持 17 种界面语言：`en`、`zh-Hans`、`zh-Hant`、`ja`、`ko`、`fr`、`de`、`es`、`pt-BR`、`it`、`nl`、`ru`、`ar`、`th`、`id`、`vi`、`tr`。

在应用中打开**设置 → 通用 → 语言**。默认跟随系统，按偏好顺序选取支持的语言；全部不支持时回退英语。中文根据文字与地区标识选择简体或繁体，葡萄牙语使用巴西葡萄牙语。手动选择保存在 `UserDefaults` 的 `another-you.interface-language` 中；选择**跟随系统**会清除覆盖。主窗口、设置、菜单与快速会话使用所选语言；阿拉伯语采用从右到左布局，数字与日期按该语言格式显示。

官网语言选择使用相同的语言解析规则，同时更新页面文案、无障碍标签、页面元数据、互动示例与复制反馈。手动选择保存在 `localStorage` 的 `another-you.website-language` 中；浏览器禁止存储时仍可切换。没有已保存选择时读取浏览器语言偏好。切换语言会保留各演示场景已经作出的选择。阿拉伯语采用从右到左布局与对应的水平方向键导航；终端命令保持从左到右。

应用翻译位于 `macos/AnotherYou/Sources/AnotherYouCore/Resources/<language>.lproj/Localizable.strings`，官网翻译位于 `website/locales.js`。各语言必须拥有相同的键与兼容的格式参数，新增界面文案时应同时补齐所有语言。用户消息、模型生成内容、模型标识、第三方登录提示和外部原始诊断保留来源语言。

从仓库根目录执行专门检查：

```sh
node --check website/locales.js
node --check website/i18n.js
node --check website/script.js
node --test website/i18n.test.cjs
scripts/xcode-toolchain.sh test --package-path macos/AnotherYou --scratch-path /tmp/another-you-localization-check --filter LocalizationTests
```

测试覆盖资源与格式参数、选择持久化、系统回退、阿拉伯语布局方向、所有演示决定与剪贴板成功/失败反馈。测试不代表视觉效果或母语审校通过。还应单独验收打开窗口中的语言切换及官网窄屏布局，包括阿拉伯语、日语和较长的欧洲语言译文。测试结束后清理独立 scratch 目录，不对其他正在使用的开发实例执行 `make clean`。
