# Configuration reference

**English** | [简体中文](configuration.zh-CN.md)

Configuration is JSON, validated by [config.ts](../agent-core/src/config.ts). Omitted fields use the defaults below; malformed JSON or schema-validation errors stop startup. Start with [config.example.json](../agent-core/config.example.json), replacing its example model with one your service actually provides.

## Files and loading

| Item | Default on macOS |
| --- | --- |
| Configuration | `~/Library/Application Support/AnotherYou/config.json` |
| Runtime state | `<dataDir>/state.json` |
| Native notification preference | `UserDefaults` key `notificationsEnabled`, initially `false` |

The Swift host creates a missing configuration and passes its path to the sidecar. The CLI accepts `--config /absolute/path/config.json`; when that file is absent, it uses defaults with the file's parent as `dataDir`, without writing a configuration file. Running the core can still write `state.json`.

For an existing JSON file, `dataDir` controls state independently of the configuration path. If it is omitted, the normal platform data directory is used. Merely moving an existing config with `--config` does not isolate its state. `~` is expanded in `dataDir`; other relative paths resolve against the sidecar's working directory. Prefer absolute paths outside the repository.

The product supports macOS. The standalone core also defines data-directory defaults for Windows (`%APPDATA%/AnotherYou`) and other systems (`$XDG_DATA_HOME/another-you`, falling back to `~/.local/share/another-you`); these do not imply native-client support on those platforms.

## App configuration and Pi models

`version` is `1`, `dataDir` stores application state, and `permissionMode` is fixed to `full-access`. The legacy JSON `model` field no longer selects a runtime model.

Models, endpoints, authentication, capabilities, and thinking levels come from Pi's native configuration:

| Pi file | Purpose |
| --- | --- |
| `settings.json` | `defaultProvider`, `defaultModel`, default and per-model thinking levels. |
| `models.json` | Custom providers, local models, endpoints, compatibility parameters, and model overrides. |
| `auth.json` | Pi-managed authentication, including API keys and OAuth. |

The app uses an isolated `<dataDir>/pi` directory. It does not read `~/.pi/agent`, `PI_CODING_AGENT_DIR`, or provider keys from the host environment. Settings list all chat models from the Pi SDK and local catalog cache, support model/provider search, and save the default model and per-model thinking level. Missing defaults do not trigger selection of another provider.

Accounts use the API-key and OAuth methods supplied by the Pi SDK, including web, device-code, and manual-code flows with cancellation. Credentials are written only to the isolated `auth.json`; the directory uses mode `0700`, and configuration/authentication files use `0600`. Authentication prompts and replies are sent through the live protocol without entering conversation or state history. The app does not execute credential commands or resolve environment-based credentials; such references are marked as requiring configuration and must be removed when setting up the account in the app.

“Import Pi configuration…” accepts `models.json` or its directory, plus optional `settings.json` from the same directory. It imports model definitions and a valid default selection, removes API keys, headers, and authentication environment fields, does not copy the source `auth.json`, and preserves current accounts. Existing personal Pi configuration remains unchanged.

For local Ollama, place this example in **Pi's models.json**:

```json
{"providers":{"ollama":{"baseUrl":"http://localhost:11434/v1","api":"openai-completions","apiKey":"ollama","models":[{"id":"qwen3:8b"}]}}}
```

After saving custom models, click “Reload configuration”, select a model, and click “Use this model”. Startup and reload restore local configuration and cached catalogs. “Update model catalog” explicitly asks the SDK to refresh configured providers; successful partial updates remain visible if another refresh fails. Model configuration changes are blocked during a model request or account operation. `model.configured` means credentials are configured; `model.available` describes the latest request outcome. Saving configuration or refreshing a catalog does not prove model availability or send a test prompt.

## Privacy and network fields

| Field | Type / default | Meaning |
| --- | --- | --- |
| `privacy.mode` | String, `local-first` | Legacy values are accepted and normalized to `local-first`. |
| `privacy.allowNetwork` | Boolean, `true` | Always enabled in full-access mode. |
| `privacy.allowedNetworkHosts` | String array, `[]` | Legacy compatibility; full access does not use a host allowlist. |
| `privacy.storePrompts` | Boolean, `true` | Retain prompt/context/signal content in persisted state. |
| `privacy.storeResponses` | Boolean, `true` | Retain response text in persisted state. |
| `privacy.redactSecrets` | Boolean, `true` | Apply basic credential-pattern redaction when saving state. |

Model requests follow Pi provider configuration, authentication, and protocol handling. The app no longer maintains separate model endpoint validation. Content-storage flags only control Another You state persistence.

## Tool declarations and native notifications

| Field | Default |
| --- | --- |
| `tools.filesystem` | `true` |
| `tools.shell` | `true` |
| `tools.network` | `true` |
| `tools.calendar` | `false` |
| `tools.notifications` | `true` |

The runtime provides file read/write, directory listing, shell, and HTTP tools for direct execution. The first three tool flags are always enabled; legacy restrictions are migrated. `calendar` remains a compatibility declaration with no bundled calendar connector. macOS still manages operating-system permissions.

Native notifications are controlled by `AssistantStore`, a separate `UserDefaults` preference, and macOS permission. `tools.notifications` does not enable or disable them. Notifications require a packaged app, user opt-in, an inactive app, and an unpaused suggestion event; delivery still depends on macOS. See the [macOS guide](../macos/AnotherYou/README.md).

## Scheduler fields

| Field | Type / default | Meaning |
| --- | --- | --- |
| `scheduler.enabled` | Boolean, `true` | Enable proactive signal processing. Disabling it leaves explicit model requests available. |
| `scheduler.pollIntervalMs` | Number, `30000` | Core tick interval; at least 100 ms. |
| `scheduler.defaultCooldownMs` | Number, `1800000` | Default per-rule cooldown, 30 minutes. |
| `scheduler.defaultDedupeWindowMs` | Number, `300000` | Default deduplication window, 5 minutes. |

Durations must be finite and non-negative; configuration values are rounded down to integer milliseconds. Individual rules can override cooldown and deduplication. The built-in rules use their own cooldowns. Rule definitions and examples are in the [CLI reference](cli-reference.md). The Swift idle sampler has its own fixed 30-second interval; changing `pollIntervalMs` does not change that sampler.

## Proactive work-analysis fields

| Field | Default | Meaning |
| --- | ---: | --- |
| `proactive.enabled` | `true` | Enable background collection and analysis; pausing proactive suggestions also stops pending collection. |
| `proactive.workIntervalMs` | `300000` | Work-window check interval, 5 minutes. |
| `proactive.notificationsIntervalMs` | `180000` | Accessible notification-content check interval, 3 minutes. |
| `proactive.synthesisIntervalMs` | `600000` | Parent-agent synthesis interval, 10 minutes. |
| `proactive.suggestionCooldownMs` | `900000` | Minimum interval between proactive suggestions, 15 minutes. |
| `proactive.taskSpacingMs` | `30000` | Minimum spacing between background tasks, 30 seconds. |
| `proactive.collectionTimeoutMs` | `15000` | Swift collection-response timeout. |
| `proactive.taskTimeoutMs` | `90000` | Total subagent or parent-agent timeout. |

Work and notification tasks run separately; content fingerprints, notification digests, and suggestion cooldowns persist across restarts. Unchanged content skips model calls, and failures use exponential backoff. Subagents only analyze and return structured facts; the parent agent decides whether to create one suggestion. Background agents have no file, shell, network, or desktop-execution tools. macOS collection reads only the currently visible Accessibility text from the frontmost work window and Notification Center; it does not take screenshots, scan notification databases, or read files. Permission, locked-session, and disappeared-notification states are explicit.

## What state retains

State includes rules, pause state, proposal states, cooldown timestamps, hashed deduplication keys, up to 200 history events, separate `usageRecords` retained for 30 days (tokens, model, reasoning depth, tool calls, and outcome), and up to 100 completed/ignored proposals in total. Pending, running, snoozed, and failed proposals remain retained. Status events are not added to the history. An interrupted running proposal becomes failed on restart and is not automatically retried.

- `storePrompts=false` removes `prompt`, `context`, and `signal` from persisted history, clears proposal context, and removes rule context. Rule titles/messages and proposal titles/summaries remain; this is not a switch that erases every piece of user text.
- `storeResponses=false` removes history and proposal `text` fields.
- If either content-storage switch is off, persisted `agent.error` details are replaced with a generic message. Failed-proposal text is omitted when prompt storage is off, and all proposal text is omitted when response storage is off.
- `redactSecrets=true` masks common `sk-`, GitHub token, Bearer, API-key, password, secret, and token patterns, including recognized nested field names. It cannot identify arbitrary private text.

These controls operate on the saved copy, not the live JSONL stream or in-memory state, and do not erase existing files until a new save occurs. Deduplication keys are SHA-256 digests. State is written through a temporary file and atomic rename with mode `0600`; newly created state directories request `0700`. Swift also writes configuration atomically with `0600` permissions. The app does not encrypt either file. A malformed state file produces an error; preserve it for repair instead of assuming it was reset.

## Environment and build overrides

| Name | Consumer / effect |
| --- | --- |
| `ANOTHER_YOU_DATA_DIR` | Swift host: directory containing `config.json`. New application configuration sets `dataDir` to that directory. The standalone Node CLI does not read this variable; use `--config` and `dataDir`. |
| `ANOTHER_YOU_AGENT_ROOT` | Swift host: explicit absolute path to `agent-core`; takes precedence over bundle/development lookup. |
| `ANOTHER_YOU_NODE` | Swift host and packaging: explicit Node executable path. It does not select the `npm` executable used for installation. |
| `OUTPUT_DIRECTORY` | Packaging: output directory, default `dist/macos`; `make run`/`make update` use fixed `dist/dev` instead. |
| `BUNDLE_NODE` | Packaging: `0` for machine-provided Node, `1` to copy a compatible self-contained Node; default `0`. |
| `APP_VERSION` / `APP_BUILD` | Packaging: version and build, default `0.1.0` / `1`. |
| `BUILD_ARCH` | Packaging: `arm64` or `x86_64`, default host architecture. |
| `ANOTHER_YOU_NODE_LICENSE` | Packaging: explicit Node license; bundled Node requires an adjacent license or this path. |
| `PORT` | `make website`: loopback preview port, default `4173`. |
| `PI_GIT_TRANSPORT` | Source bootstrap: `ssh` selects the configured GitHub SSH transport; default HTTPS. |
| `PI_SOURCE_DIR` | Source bootstrap: override the default `agent-core/.cache/pi`. |
| `PI_SOURCE_LOCK` | Source bootstrap: override the default `agent-core/pi-source.lock.json`. |

Use absolute paths for runtime overrides. An explicit missing Agent or Node path causes an error rather than falling back. The Swift host normally tries bundled resources before development paths or system Node. `ANOTHER_YOU_DATA_DIR` does not relocate the `UserDefaults` notification preference. See [packaging](releasing.md) and [sources](sources.md) for the relevant commands.

App update preferences use the `UserDefaults` keys `SUEnableAutomaticChecks`, `SUAutomaticallyUpdate`, and `AnotherYouAutomaticallyInstallsUpdates`, separate from Agent configuration. All start disabled. See [releasing](releasing.md) for feeds, public keys, and release environment variables.
