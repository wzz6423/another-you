# Another You for macOS

**English** | [简体中文](README.zh-CN.md)

The native SwiftUI client for the 0.1.0 development preview. It provides a main window, menu bar controls, local-model settings, and optional system notifications. The UI currently uses Chinese. Agent rules, model requests, and persisted suggestion state live in the Node sidecar.

## Run from source

Requirements: macOS 14+, Swift 6, Node.js 22.19+, and npm. Run from the repository root:

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
  swift run --package-path macos/AnotherYou AnotherYou
```

Direct execution supports the main UI and sidecar, but system notifications require an `.app` bundle. Quit through the menu bar or use `Ctrl+C` for a foreground source run.

## Connect a model

1. Start a compatible local model service separately and check the exact model name it serves. For Ollama, `ollama list` lists installed models.
2. Open **设置 → 本地模型**. Enter the service URL and model name. The usual Ollama URL is `http://127.0.0.1:11434/v1`.
3. Select **保存并重新连接**, then submit a prompt or generate a draft from a suggestion to test the connection.

The app does not install models or start their services. Saving settings only validates and writes the configuration; a successful model request is the availability check. The settings UI accepts `localhost`, `127.0.0.1`, and `::1` loopback addresses only.

Saving these settings replaces the model section with `provider=local` and `temperature=0.2`, resets privacy to `strict-local`, clears remote-host authorization, and disables `tools.network`. It preserves the content-storage preferences. Remote model settings require manual configuration and a process environment containing the selected key; see [configuration](../../docs/configuration.md). Saving through this local-model UI will overwrite that remote configuration.

## Suggestions and notifications

Suggestions come from app-launch, local-time, and actual Mac idle signals. The client samples idle duration every 30 seconds; it does not read your screen, messages, calendar, or current work. Rule cooldowns and existing unresolved suggestions prevent repeated prompts.

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
