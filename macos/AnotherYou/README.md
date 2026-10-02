# Another You for macOS

**English** | [简体中文](README.zh-CN.md)

The native SwiftUI client for the 0.1.0 development preview. It provides a main window, menu bar controls, Pi model status, and optional system notifications. The UI currently uses Chinese. Agent rules, model requests, and persisted suggestion state live in the Node sidecar.

## Run from source

The app supports macOS 14+. Source builds require full Xcode 27+ with the macOS 27+ SDK, Node.js 22.19+, and npm. Run from the repository root:

```bash
make deps
make run
```

`make run` builds and launches `dist/dev/Another You.app`. Its process record and log are stored alongside it; startup diagnostics are in `dist/dev/another-you.log`.

```bash
make stop
make update
```

`make stop` stops the development instance managed by this workspace. `make update` rebuilds and restarts the local source; it does not fetch Git changes. For a separate development app or a bundled Node runtime, see [packaging](../../docs/releasing.md).

For direct Swift development without an app bundle:

```bash
ANOTHER_YOU_AGENT_ROOT="$PWD/agent-core" \
  ./scripts/xcode-toolchain.sh run --package-path macos/AnotherYou AnotherYou
```

Direct execution supports the main UI and sidecar, but system notifications require an `.app` bundle. Quit through the menu bar or use `Ctrl+C` for a foreground source run.

Build and test commands use the full Xcode selected by `DEVELOPER_DIR` or `xcode-select`; Command Line Tools and Xcode versions below 27 are rejected. `make build SWIFT_SCRATCH_PATH=/tmp/another-you-swift` and `make test-swift SWIFT_SCRATCH_PATH=/tmp/another-you-swift` keep verification outputs separate from the default `.build` directory. Remove that temporary directory after verification.

## Use Pi models

Settings are split into General, Model, Proactive suggestions, Computer control, Shortcuts, and Software updates. The Model page shows Pi's default model, provider, and thinking level without maintaining separate model or credential settings.

1. Configure authentication (`/login`) or a model service in local Pi. Local models also belong in Pi's `models.json` or its local-model setup.
2. Select a model in Pi's `/model` and press **Ctrl+S** to save the default. Save a default thinking level in `/thinking` if needed.
3. Click **重新读取 Pi 配置** under Another You's **设置 → 模型**, then send a request to verify the model.

The app reads Pi's `settings.json`, `models.json`, and `auth.json` from `~/.pi/agent`, respecting `PI_CODING_AGENT_DIR`. Legacy Another You `model` settings no longer apply and are never migrated into Pi automatically. Missing defaults or credentials are reported explicitly; loading configuration does not verify a real request. Requests use Pi's native authentication and provider routing.

## Conversations and usage

Quick chat shows a glass capsule input, with removable screenshot previews above it when attached, centered horizontally on the screen containing the pointer, 20% above the bottom of the screen. macOS 26+ uses native Liquid Glass, with a material fallback on older systems. Return or the send shortcut submits and hides it; read replies in the main conversation page.

Open **会话** in the sidebar for a dedicated conversation page. While the app runs, **⌘⇧Space** opens quick chat globally; **⌘Return** sends and **Esc** hides it. Both entry points share sent messages; closing quick chat preserves the conversation. If shortcut registration fails, use the menu entry. Each conversation uses its own latest 20 successful turns as context, separate from other conversations and proposal drafts. The sidecar persists titles, state, and complete message history per conversation; restoration respects content-storage preferences. Screenshot binaries are not persisted or silently resent in later turns.

The home board has **In progress / Completed** columns for conversations and proactive suggestions, with optional grouping by the application associated with a screenshot. Open a conversation to continue it, or a suggestion to review and decide. Item menus support archive and delete. **Settings → Archived conversations** lets you review, restore, or delete archived items. Stop a running conversation before archiving or deleting it; the UI waits for the sidecar acknowledgement.

**Activity** shows individual thinking, execution, command, and application-context stages, with category filters and grouping. Thinking logs contain stage metadata only, never the model’s private reasoning text.

The dashboard pie chart shows model Token shares for **24h / 7d / 15d / 30d**, with input, output, cache, model rankings, reasoning depth, and tool calls. Records begin with this version and remain for 30 days, including reported usage from failures. Missing usage is labeled as unreported, never estimated. Plugin / Skill / MCP appear only when the runtime records such calls; no corresponding connectors are bundled yet.

## Suggestions and notifications

Suggestions come from app-launch, local-time, and actual Mac idle signals. Idle duration is sampled every 30 seconds. Screenshots and application context are obtained through conversation actions and collectors with the required macOS permissions. Rule cooldowns and existing unresolved suggestions prevent repeated prompts.

Choose **生成草稿**, **稍后**, or **忽略** on a suggestion. Snooze defaults to 15 minutes; due suggestions return while the runtime is running and proactive scheduling is enabled and unpaused. Draft generation changes the suggestion only after the sidecar acknowledges the decision. A failure can be retried manually. **暂停主动建议** survives restarts and does not cancel a model request already submitted.

System notifications are off initially. From the packaged app, enable **设置 → 介入方式 → 新建议显示系统通知** and allow macOS notification permission. A new suggestion event can request a notification when the app is inactive and proactive suggestions are not paused. Loading stored cards does not itself notify. macOS settings and Focus can affect delivery, so enabling the option is not proof that a notification was delivered.

The notification preference is stored in `UserDefaults` under `notificationsEnabled`. It is separate from `config.json` and `tools.notifications`; changing that Agent field does not switch native notifications on or off. The app must be running to observe signals; launch at login and scheduling while the app is closed are not implemented.

## Runtime paths and troubleshooting

| Symptom | Check |
| --- | --- |
| Agent cannot be found | Run from the repository root or set `ANOTHER_YOU_AGENT_ROOT` to the absolute `agent-core` path. Packaged apps normally load it from resources. |
| Node is missing or exits early | Check Node 22.19+ and run `make deps`. Set `ANOTHER_YOU_NODE` to an absolute executable path if needed. |
| Agent does not respond within 12 seconds | Inspect the displayed startup error and development log; check Node, dependencies, and malformed configuration/state. |
| Model is unconfigured or a request fails | Confirm the model name, service availability, endpoint compatibility, and the error shown under runtime status. |
| Notifications are unavailable | Use the packaged app; check its opt-in, macOS permission, inactive state, and whether a new suggestion can fire after cooldown. |
| No new suggestion appears | Check pause/configuration, local time, cooldown, and unresolved cards. The welcome rule is limited to once per 24 hours. |

Configuration and state normally live under `~/Library/Application Support/AnotherYou/`. `ANOTHER_YOU_DATA_DIR` selects a different directory for the Swift host. Use an absolute path outside the repository to isolate development data. This variable does not isolate the separate `UserDefaults` notification preference. See [configuration](../../docs/configuration.md) for file behavior and storage limits.

## Verification and cleanup

From the repository root:

```bash
make deps
make test-swift
make clean
```

[AnotherYouCoreTests.swift](Tests/AnotherYouTests/AnotherYouCoreTests.swift) covers JSONL framing, settings, runtime discovery, acknowledged UI state, process recovery, and a real Node sidecar round trip. The sidecar tests need npm dependencies but no real model. Manually verify changed window/menu interactions, real-model requests, and notifications separately.

`make clean` stops the managed development app and removes known build/test outputs. It preserves personal app data, dependencies, the Pi source cache, and custom package directories.

## Code and related documents

[AgentClient.swift](Sources/AnotherYouCore/AgentClient.swift) owns the process and protocol; [AssistantStore.swift](Sources/AnotherYouCore/AssistantStore.swift) adapts events to UI state and samples idle duration. [AgentSettings.swift](Sources/AnotherYouCore/AgentSettings.swift) owns local settings persistence. [MainWindowView.swift](Sources/AnotherYouCore/MainWindowView.swift) contains the views, and [main.swift](Sources/AnotherYou/main.swift) creates the window, settings scene, and menu bar.

Read [architecture](../../docs/architecture.md), [CLI and JSONL protocol](../../docs/cli-reference.md), and [contributing](../../CONTRIBUTING.md) before changing the Swift/Node boundary.

## Shortcuts, screenshots, and background interaction

[Shortcuts, screenshots, and background interaction](../../docs/desktop-automation.md) covers recording all shortcuts, screenshot previews, macOS permissions, and interaction boundaries.
