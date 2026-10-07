# Another You for macOS

**English** | [简体中文](README.zh-CN.md)

The native SwiftUI client for the 0.1.0 development preview. It provides a main window, menu bar controls, Pi model status, and optional system notifications. The UI currently uses Chinese. Agent rules, model requests, and persisted suggestion state live in the Node sidecar.

Debug apps use the dark icon; Release apps use the light icon in Finder and the Dock, regardless of appearance. The sidebar logo follows the app's light, dark, or system appearance setting, and the menu bar uses a monochrome template of the same mark. Brand assets are bundled from [Resources](Sources/AnotherYouCore/Resources).

## Run from source

The app supports macOS 14+. Source builds require full Xcode 27+ with the macOS 27+ SDK, Node.js 22.19+, and npm. Run from the repository root:

```bash
make deps
make run
```

`make run` builds and launches `dist/dev/Another You.app` in Debug mode, with the display name **Another You Debug** and bundle identifier `com.anotheryou.mac.debug`. Its process record and log are stored alongside it; startup diagnostics are in `dist/dev/another-you.log`.

```bash
make stop
make update
```

The Debug app defaults to `~/Library/Application Support/AnotherYouDebug/`, keeping its configuration, state, and preferences separate from the Release app. `ANOTHER_YOU_DATA_DIR` overrides the data path.

`make stop` stops the development instance managed by this workspace. `make update` rebuilds and restarts the local source in Debug mode; it does not fetch Git changes. `make build-package` produces a separate Release app. For bundled Node details, see [packaging](../../docs/releasing.md).

For direct Swift development without an app bundle:

```bash
ANOTHER_YOU_AGENT_ROOT="$PWD/agent-core" \
  ./scripts/xcode-toolchain.sh run --package-path macos/AnotherYou AnotherYou
```

Direct execution supports the main UI and sidecar, but system notifications require an `.app` bundle. Quit through the menu bar or use `Ctrl+C` for a foreground source run.

Build and test commands use the full Xcode selected by `DEVELOPER_DIR` or `xcode-select`; Command Line Tools and Xcode versions below 27 are rejected. `make build SWIFT_SCRATCH_PATH=/tmp/another-you-swift` and `make test-swift SWIFT_SCRATCH_PATH=/tmp/another-you-swift` keep verification outputs separate from the default `.build` directory. Remove that temporary directory after verification.

## Use Pi models

Settings are split into General, Model, Proactive suggestions, Computer use, Shortcuts, and Software updates. Computer use and background Browser use are enabled by default. The Computer use page provides Screen Recording and Accessibility permission controls; there are no separate browser settings. The Model page manages the app's isolated Pi model and account configuration directly.

1. Select a provider under **Settings → Model**, or choose **Custom API** to add a compatible service.
2. Enter the endpoint, protocol, API key, and model ID, then click **Save and use**. Saved keys are masked; click the eye to reveal one, or leave the key blank when saving to retain it. Each provider supports multiple named accounts and switching their complete configuration. For web login or other authentication methods, authenticate first, select a model and thinking level, and click **Use this model**.
3. Click **Test connection** to check the actual request outcome; saving does not prove availability. **Import Pi models** reads local Pi configuration directly, without a file picker; custom APIs use the form above.

The app automatically discovers Pi's `settings.json`, `models.json`, and `auth.json` in `~/.pi/agent`, respecting `PI_CODING_AGENT_DIR`. The first valid discovery copies models and accounts into an independent `<dataDir>/pi/models.sqlite` database snapshot, with existing app configuration taking precedence. Later source changes do not overwrite app choices or restore logged-out accounts. Without local Pi, accounts can still be configured in Settings. Legacy Another You `model` settings no longer apply, and the app never writes back to personal Pi configuration. Missing defaults or credentials are reported explicitly; loading configuration does not verify a real request. Requests use Pi's native authentication and provider routing.

## Conversations and usage

Quick chat shows a compact 44pt glass capsule with a black overlay fading from top to bottom, centered horizontally on the screen containing the pointer, 20% above the bottom of the screen. macOS 26+ uses native Liquid Glass; earlier systems fall back to frosted glass. The right side contains a red close button and a blue run button; closing preserves the draft. Removable screenshot previews appear above the input when attached. Return, the send shortcut, or the run button submits and hides it; read replies in the main conversation page.

Open **会话** in the sidebar for a dedicated conversation page. While the app runs, **⌘⇧Space** opens quick chat globally; **⌘Return** sends and **Esc** hides it. Each quick-chat invocation reserves a separate conversation, which appears on the board after sending. Opening or closing without sending creates no empty record, and closing preserves the unsent draft. New and old conversations can run concurrently. Returning to the board, switching conversations, and reopening quick chat do not stop existing tasks; Stop in a conversation only cancels that conversation. Sent conversations remain on the board; open a historical conversation to continue it. If shortcut registration fails, use the menu entry. Each conversation uses its own latest 20 successful turns as context, separate from other conversations and proposal drafts. The sidecar persists titles, state, and complete message history per conversation; restoration respects content-storage preferences. Screenshot binaries are not persisted or silently resent in later turns.

The **Conversations** page has **In progress / Completed** columns for conversations and proactive suggestions, with optional grouping by the application associated with a snapshot. The three-dot menu offers pin/unpin, archive/restore, and delete actions. Pinned entries appear first within their column and application group, and pinning persists across restarts. Search matches conversation and suggestion titles or associated application names, ignoring case and surrounding whitespace. Matching archived entries are shown while searching; clearing the search restores the full board and its previous archive expansion state. **Archived conversations** is collapsed by default and supports viewing, restoring, and deleting entries.

A separated composer below the board creates a conversation only on the first send; switching preserves each conversation’s unsent text and snapshot attachments. Opening a conversation shows its full context, follow-up input, export, and actions to branch from a turn or the entire conversation. Replies support CommonMark / GFM: six heading levels, emphasis, strikethrough, nested lists, task lists, quotes, rules, aligned tables, automatic and reference links, images, highlighted code, and safe HTML formatting, with selectable text. Extensions include KaTeX math (dollar delimiters, \(…\), \[…\], math environments, and math/latex fences), Mermaid diagrams, and footnotes. Wide code and tables scroll within the reply. Archived details can be restored directly. Branches retain their source without changing the original or adding duplicate usage. Suggestions open for review and a decision. Stop running conversations before managing them; the UI waits for sidecar acknowledgements. See [Exports](../../docs/exporting.md) for conversation Markdown and home usage CSV contents and limitations.

The Markdown parser, KaTeX fonts, Mermaid, and HTML sanitizer ship with the app for offline rendering. Remote images still need network access; scripts and embedded pages from replies are not executed. Sources live in `MarkdownRenderer/`. Rebuild bundled resources with `npm ci --prefix macos/AnotherYou/MarkdownRenderer --ignore-scripts` and `npm run build --prefix macos/AnotherYou/MarkdownRenderer`; run syntax tests with `npm test --prefix macos/AnotherYou/MarkdownRenderer`. `make test-swift` also exercises the actual WebKit renderer.

**Activity** shows individual thinking, execution, command, and application-context stages, with category filters and grouping. Thinking logs contain stage metadata only, never the model’s private reasoning text.

The dashboard pie chart shows model Token shares for **24h / 7d / 15d / 30d**, with input, output, cache, model rankings, reasoning depth, and tool calls. Records begin with this version and remain for 186 days, including reported usage from failures. Missing usage is labeled as unreported, never estimated. Plugin / Skill / MCP appear only when the runtime records such calls; no corresponding connectors are bundled yet.

Home **Activity statistics** provides a daily Token heatmap for the last **6 months**, using fixed **50M / 100M / 150M / 200M / 250M** thresholds (M means million tokens). Unreported usage is distinguished from reported zero usage. Square cells fill the available width automatically, with no time-range selection, and statistics include all applications and unlinked records. The charts below continue to show today’s hourly event counts in local time and event counts by application. Each accepted message and each newly created proactive suggestion counts once. Background analysis, suggestion reminders or execution, and conversation forks do not add events. Application attribution uses the current snapshot, an existing conversation association, or suggestion context; missing associations appear as unlinked. Statistics metadata is retained independently for 186 days and survives conversation archiving or deletion. Upgrades migrate only existing historical events; previously removed history is not reconstructed.

## Suggestions and notifications

Suggestions combine running applications and processes, linked projects, open documents and multiple windows, recent local files and browsing records, and accessible notifications. **Settings → Proactive suggestions → Work and notifications → Lookback period** offers **24h / 7d / 30d**, defaulting to 24h. Collection does not depend on the frontmost screen; longer content is analyzed in batches, with metadata-only and inaccessible sources identified explicitly. App launch, local time, and actual idle signals can still trigger rules. Idle is sampled every 30 seconds, while cooldowns and unresolved suggestions prevent repeated prompts.

Choose **生成草稿**, **稍后**, or **忽略** on a suggestion. Snooze defaults to 15 minutes; due suggestions return while the runtime is running and proactive scheduling is enabled and unpaused. Draft generation changes the suggestion only after the sidecar acknowledges the decision. A failure can be retried manually. **暂停主动建议** survives restarts and does not cancel a model request already submitted.

Proactive suggestions and system notifications are enabled by default; existing pause, disabled configuration, and notification choices are preserved. When the packaged app is active and notifications are enabled, it automatically requests undetermined notification permission, without waiting for the Agent to connect or proactive suggestions to resume. Enabling notifications in **Settings → Proactive suggestions** also requests permission. The one-time Accessibility request for reading work and notification text still requires a connected Agent and enabled, unpaused suggestions. Declined notification permission switches notifications off. Accessibility is not requested repeatedly after a denial; use **Settings → Proactive suggestions → Accessibility** to request it again. Text collection does not require Screen Recording; snapshots still require separate authorization in Computer use settings. A new suggestion event can request a notification when the app is inactive and suggestions are unpaused. Loading saved cards does not notify. macOS settings and Focus can affect delivery, so enabling the option does not prove delivery.

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
