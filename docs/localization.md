# Interface languages

[简体中文](localization.zh-CN.md) | **English**

The macOS app and website support 17 interface languages: `en`, `zh-Hans`, `zh-Hant`, `ja`, `ko`, `fr`, `de`, `es`, `pt-BR`, `it`, `nl`, `ru`, `ar`, `th`, `id`, `vi`, and `tr`.

In the app, open **Settings → General → Language**. The initial selection follows the system. A supported system language is chosen in preference order; unsupported preferences fall back to English. Chinese script and region tags resolve to Simplified or Traditional Chinese, and Portuguese variants use Brazilian Portuguese. An explicit selection persists in `UserDefaults` under `another-you.interface-language`. Choosing **System default** clears that override. The main window, settings, menus, and quick chat use the selected language; Arabic uses right-to-left layout. Number and date displays use that locale.

The website language picker applies the same language resolution and changes text, accessible labels, page metadata, interactive examples, and copy feedback. The explicit selection persists in `localStorage` under `another-you.website-language`; unavailable browser storage does not prevent switching. Without a saved choice, browser language preferences are used. Changing language preserves each demo scenario's current decision. Arabic uses right-to-left layout and matching horizontal arrow navigation; shell commands retain left-to-right order.

App translations live in `macos/AnotherYou/Sources/AnotherYouCore/Resources/<language>.lproj/Localizable.strings`. Website translations live in `website/locales.js`. Every language must contain the same keys and compatible format arguments. Add a translation to every language when adding interface text. User messages, generated responses, model identifiers, third-party sign-in prompts, and raw external diagnostics retain their source language.

Run the dedicated checks from the repository root:

```sh
node --check website/locales.js
node --check website/i18n.js
node --check website/script.js
node --test website/i18n.test.cjs
scripts/xcode-toolchain.sh test --package-path macos/AnotherYou --scratch-path /tmp/another-you-localization-check --filter LocalizationTests
```

The tests verify resource coverage and formatting, selection persistence, system fallback, Arabic layout direction, all demo decisions, and clipboard success/fallback messages. They do not establish visual quality or native-speaker review. Separately check language switching in open windows and the website at narrow widths, including Arabic, Japanese, and longer European translations. Remove the scratch directory after the test has finished; do not run `make clean` against another running development instance.
