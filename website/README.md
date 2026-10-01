# Another You website

**English** | [简体中文](README.zh-CN.md)

A static product page in Chinese, introducing proactive suggestions, user control, and local operation. There is no build step, frontend dependency, external font, analytics script, account form, or live Agent connection.

## Preview

From the repository root:

```bash
make website
```

Open [http://127.0.0.1:4173](http://127.0.0.1:4173). Use `make website PORT=4174` to choose another port; stop the foreground server with `Ctrl+C`. Python 3 is required. The equivalent direct command is:

```bash
python3 -m http.server 4173 --bind 127.0.0.1 --directory website
```

You can also open [index.html](index.html) directly. If the browser does not permit clipboard access, the page selects the startup command for manual copying.

## Files and behavior

| File | Purpose |
| --- | --- |
| [index.html](index.html) | Content, navigation, demo controls, startup instructions |
| [styles.css](styles.css) | Layout, typography, responsive styles, reduced motion |
| [script.js](script.js) | Scenario selection, demo decisions, reset, copying |
| [mark.svg](mark.svg) | Project brand mark |

The demo has time, event, and idle scenarios. Clicking a tab or using arrow keys, Home, or End selects a scenario. Each scenario keeps its own draft/snooze/ignore choice in page memory and can be reset independently. Reloading the page clears the choices.

All drafts and reasons are fixed examples. The page does not read device activity, call a model, send notifications, or persist personal data. Its sample times and cooldown text are illustrative; the runtime defaults are documented in the [CLI reference](../docs/cli-reference.md).

## Verification

From the repository root:

```bash
node --check website/script.js
```

For browser verification, check:

- Desktop and narrow mobile layouts, including 320–390 px widths and horizontal overflow.
- All three scenarios and all three decisions, switching between stored choices, and reset.
- Tab focus, arrow/Home/End navigation, reason disclosure, and status announcements.
- Copy success and the manual-selection fallback when clipboard access is denied.
- Reduced motion and local navigation/asset links.

Syntax checks do not establish visual or interaction quality. Keep screenshots and temporary browser outputs outside the repository and remove them when no longer needed.

## Publishing and content

A static host can serve this directory with `index.html` as its entry point. The repository has no website deployment configuration or established public deployment.

The product is a development preview and its repositories require access. The main call to action leads to source-running instructions, not an installer. Keep the page aligned with implemented behavior: Calendar, Mail, Notes, screen reading, notarized distribution, and automatic updates are not available.

Today and Google Antigravity are design references. The layout, project graphics, and wording are original to this project; reference links and adoption boundaries are in [sources](../docs/sources.md). Project documentation has English and Chinese versions; the website UI itself is currently Chinese only.
