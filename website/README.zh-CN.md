# Another You 官网

[English](README.md) | **简体中文**

支持 17 种语言的静态产品页面，介绍主动建议、用户控制和本地运行。无需构建，没有前端依赖、外部字体、分析脚本、账号表单或真实 Agent 连接。

## 预览

从仓库根目录执行：

```bash
make website
```

打开 [http://127.0.0.1:4173](http://127.0.0.1:4173)。通过 `make website PORT=4174` 更换端口，使用 `Ctrl+C` 停止前台服务。需要 Python 3。等价的直接命令为：

```bash
python3 -m http.server 4173 --bind 127.0.0.1 --directory website
```

也可以直接打开 [index.html](index.html)。浏览器不允许访问剪贴板时，页面会选中启动命令，供手动复制。

## 文件与行为

| 文件 | 用途 |
| --- | --- |
| [index.html](index.html) | 文案、导航、演示控件与启动说明 |
| [styles.css](styles.css) | 布局、字体、响应式样式与减少动态效果 |
| [locales.js](locales.js)、[i18n.js](i18n.js) | 翻译词典、语言解析、元数据与 RTL |
| [script.js](script.js) | 场景选择、演示决定、重置和复制 |
| [logo-light.png](logo-light.png)、[logo-dark.png](logo-dark.png) | 已选定的日夜标志，分别用于浅色和深色区域 |
| [favicon-light.png](favicon-light.png)、[favicon-dark.png](favicon-dark.png)、[apple-touch-icon.png](apple-touch-icon.png) | 随系统外观切换的浏览器图标及 Apple 触屏图标 |

演示包含时间、事件与闲置三种场景。点击标签或使用方向键、Home、End 可切换场景。每个场景分别在页面内存中保留生成草稿/稍后/忽略的选择，并可独立重置；刷新页面后清空。

所有草稿与触发理由都是固定样例。页面不读取设备活动、不调用模型、不发送通知，也不持久保存个人数据。示例时间与冷却文案只用于演示，运行时默认值以 [CLI 参考](../docs/cli-reference.zh-CN.md) 为准。

## 验证

从仓库根目录执行：

```bash
node --check website/locales.js
node --check website/i18n.js
node --check website/script.js
node --test website/i18n.test.cjs
```

浏览器验收应检查：

- 17 种语言、选择持久化、系统语言回退、阿拉伯语 RTL，以及演示和复制反馈的翻译。
- 桌面和手机窄屏布局，包括 320–390 px 宽度及横向溢出。
- 三种场景与三种回应、切换后保留各自选择，以及重置。
- Tab 焦点、方向键/Home/End 导航、触发原因展开和状态播报。
- 正常复制，以及剪贴板被拒绝时的手动选择回退。
- 减少动态效果设置和本地导航/资源链接。

语法检查不能证明视觉与交互质量。截图和浏览器临时输出应放在仓库外，不再需要时清理。

## 发布与内容

静态托管服务可直接发布本目录，入口为 `index.html`。仓库目前没有官网部署配置，也没有已确立的公网部署。

产品处于开发预览，仓库已开源。主按钮指向源码运行说明，不提供安装包。页面文案应与当前实现一致：已配置的正式包支持自动更新，但公开安装包、公证分发和 Homebrew cask 尚未发布。其他能力以当前实现与对应文档为准。

Today 与 Google Antigravity 是设计参考。页面布局、项目图形与文案为本项目原创，参考链接和采用边界见 [来源](../docs/sources.zh-CN.md)。项目文档提供中英文版本，官网 UI 支持 17 种语言。语言选择、持久化、回退与翻译维护见[界面语言](../docs/localization.zh-CN.md)。
