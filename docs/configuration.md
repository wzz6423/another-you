# Configuration reference

**English** | [简体中文](configuration.zh-CN.md)

Configuration is JSON, validated by [config.ts](../agent-core/src/config.ts). Omitted fields use the defaults below; malformed JSON or schema-validation errors stop startup. Start with [config.example.json](../agent-core/config.example.json), replacing its example model with one your service actually provides.

## Files and loading

| Item | Default on macOS |
| --- | --- |
| Configuration | `~/Library/Application Support/AnotherYou/config.json` |
| Runtime state | `<dataDir>/state.json` |
| Native notification preference | `UserDefaults` key `notificationsEnabled`, initially `true`; existing explicit choices are preserved |

The Debug app launched by `make run/update` defaults to `~/Library/Application Support/AnotherYouDebug/` and isolates system preferences through its own bundle identifier. `ANOTHER_YOU_DATA_DIR` overrides the data path. The table above applies to the Release app and standalone CLI.

The Swift host creates a missing configuration and passes its path to the sidecar. The CLI accepts `--config /absolute/path/config.json`; when that file is absent, it uses defaults with the file's parent as `dataDir`, without writing a configuration file. Running the core can still write `state.json`.

For an existing JSON file, `dataDir` controls state independently of the configuration path. If it is omitted, the normal platform data directory is used. Merely moving an existing config with `--config` does not isolate its state. `~` is expanded in `dataDir`; other relative paths resolve against the sidecar's working directory. Prefer absolute paths outside the repository.

The product supports macOS. The standalone core also defines data-directory defaults for Windows (`%APPDATA%/AnotherYou`) and other systems (`$XDG_DATA_HOME/another-you`, falling back to `~/.local/share/another-you`); these do not imply native-client support on those platforms.

## App configuration and Pi models

`version` is `1`, `dataDir` stores application state, and `permissionMode` is fixed to `full-access`. The legacy JSON `model` field no longer selects a runtime model.

Models, endpoints, authentication, capabilities, and thinking levels for conversations and remote assistance are stored in `<dataDir>/pi/models.sqlite`; the Pi SDK handles authentication and requests. Startup can migrate or discover the Pi files below. Proactive assistance uses the separate local-model configuration described later:

| Pi import file | Purpose |
| --- | --- |
| `settings.json` | `defaultProvider`, `defaultModel`, default and per-model thinking levels. |
| `models.json` | Custom providers, local models, endpoints, compatibility parameters, and model overrides. |
| `auth.json` | Pi-managed authentication, including API keys and OAuth. |

The app uses an isolated `<dataDir>/pi` directory. On startup or reload, it discovers local configuration through Pi SDK's official path: `PI_CODING_AGENT_DIR` when set, otherwise `~/.pi/agent`. The first valid discovery automatically copies model definitions, API key / OAuth accounts, the default model, and thinking levels. Existing app provider definitions, accounts, default selection, and explicit thinking levels take precedence. Only global model settings are read; Pi project settings, extensions, tool settings, and provider keys from the host environment are not imported.

The first upgrade transactionally migrates configuration, credentials, and catalog caches from the app's isolated Pi directory into SQLite. Successfully migrated JSON files are removed; migration failures retain the originals. The personal Pi directory is not cleaned. Discovery markers are also stored in the database. Later changes or removal of the source Pi configuration do not overwrite app configuration, and logged-out accounts are not automatically restored. Without local Pi configuration, accounts can be configured directly in the app. Invalid source files do not disable existing app configuration; fix the source and choose “Reload configuration” to retry. The app never writes back to the personal Pi directory, and neither running nor packaging requires a local Pi installation.

Select a provider in Settings. OpenAI, Anthropic, and ordinary custom API providers offer a complete form for the endpoint (Base URL), API protocol, API key, and model ID. Choose a model from the catalog or enter its ID, then click “Save and use”. “Custom API” adds an independent provider supporting OpenAI Chat Completions, OpenAI Responses, or Anthropic Messages. Leave the key blank to retain an existing API-key credential; an OAuth account cannot substitute for a missing API key. Form drafts survive switching settings pages or reopening settings; saving successfully or disconnecting clears the entered key. Saving merges the provider and model, preserves other providers, models, and capabilities, and removes the target's old authentication headers so they cannot override the new key. A failed save restores the previous configuration.

Other account methods require authentication before searching the provider's chat models from the Pi SDK and local cache and saving a default model and thinking level. The saved model's provider is selected first, followed by an existing configured account. The app does not choose an arbitrary model.

Each provider can have multiple named accounts. Switching a saved account restores its endpoint, protocol, credentials, model, thinking level, and catalog cache together. Failed or cancelled saves do not leave partial configuration. Saved API keys are masked; clicking the eye reads the key through the live protocol. Hiding it, changing accounts, leaving the Model page, or disconnecting clears the revealed key. Stale replies cannot overwrite another account or a newly edited key. Keys are excluded from model catalogs, conversations, activity, and state history.

Accounts use the API-key and OAuth methods supplied by the Pi SDK, including web, device-code, and manual-code flows with cancellation. Browser authorization opens automatically, with the sign-in link and manual-code fallback retained; device codes can be copied. Current input and sign-in choices survive switching settings pages or reopening settings and are cleared when the step or login ends. For GitHub Copilot, leave the optional enterprise domain blank to use github.com. Required Cloudflare account/gateway, AWS profile, and Google Cloud project/location fields are validated before submission. The app does not automatically inherit local AWS/Google credentials; unavailable credentials are reported explicitly, so users can choose a key or token instead. Credentials are written only to local `models.sqlite`; the directory uses mode `0700` and the database uses `0600`. The database is not encrypted. Authentication prompts and replies are sent through the live protocol without entering conversation or state history. The app does not execute credential commands or resolve environment-based credentials; such references are marked as requiring configuration and must be removed when setting up the account in the app.

“Import Pi models” reads `models.json` and optional `settings.json` directly from Pi's standard directory (the SDK's `getAgentDir()`, including `PI_CODING_AGENT_DIR`) without a file picker. It imports model definitions and a valid default selection, preserves existing local providers and conflicting configuration, removes API keys, headers, and authentication environment fields from imported content, and does not copy the source `auth.json`. Existing personal Pi configuration remains unchanged. Configure custom APIs using the provider, base URL, API protocol, API Key, and model ID form above.

For local Ollama, place this example in **Pi's models.json**:

```json
{"providers":{"ollama":{"baseUrl":"http://localhost:11434/v1","api":"openai-completions","apiKey":"ollama","models":[{"id":"qwen3:8b"}]}}}
```

After editing personal Pi's `models.json`, click “Import Pi models”, then configure the account and save the model using the provider's form. Existing conflicting configuration takes precedence; use the app form for routine edits. Startup and “Reload configuration” restore database configuration and cached catalogs. “Update model catalog” explicitly asks the SDK to refresh configured providers; successful partial updates remain visible if another refresh fails. Model configuration changes are blocked during a model request or account operation. `model.configured` means credentials are configured; `model.available` describes the latest request outcome. Saving configuration or refreshing a catalog does not prove model availability or send a test prompt.

“Test connection” sends an independent short request to the saved model and displays untested, testing, succeeded, or failed status. The request has no tools or conversation context and is not added to a conversation. It can be cancelled and has a 60-second deadline. After failure, reconfigure the account or select another model and retry. This action makes a real request to the configured service; local fixture tests do not prove availability of another service or account.

## Privacy and network fields

| Field | Type / default | Meaning |
| --- | --- | --- |
| `privacy.mode` | String, `local-first` | Legacy values are accepted and normalized to `local-first`. |
| `privacy.allowNetwork` | Boolean, `true` | Always enabled in full-access mode. |
| `privacy.allowedNetworkHosts` | String array, `[]` | Legacy compatibility; full access does not use a host allowlist. |
| `privacy.storePrompts` | Boolean, `true` | Retain prompt/context/signal content in persisted state. |
| `privacy.storeResponses` | Boolean, `true` | Retain response text in persisted state. |
| `privacy.redactSecrets` | Boolean, `true` | Apply basic credential-pattern redaction when saving state. |

Model requests follow Pi provider configuration, authentication, and protocol handling. The API form validates an HTTP/HTTPS Base URL without embedded credentials, query parameters, or fragments. Saving does not send a model request. Content-storage flags only control Another You state persistence.

## Tool declarations and native notifications

| Field | Default |
| --- | --- |
| `tools.filesystem` | `true` |
| `tools.shell` | `true` |
| `tools.network` | `true` |
| `tools.calendar` | `false` |
| `tools.notifications` | `true` |

The runtime provides file read/write, directory listing, shell, and HTTP tools for direct execution. The first three tool flags are always enabled; legacy restrictions are migrated. `calendar` remains a compatibility declaration with no bundled calendar connector. macOS still manages operating-system permissions.

Native notifications are controlled by `AssistantStore`, a separate `UserDefaults` preference, and macOS permission. `tools.notifications` does not enable or disable them. New users start with notifications enabled. When the packaged app is active and notifications are enabled, it automatically requests notification permission if macOS has not recorded a decision, without waiting for the Agent to connect or proactive suggestions to resume. Enabling notifications in Settings also requests permission. A denial turns the preference off; existing disabled preferences are preserved. Delivery requires an inactive app and a new, unpaused suggestion event, and still depends on macOS. See the [macOS guide](../macos/AnotherYou/README.md).

## Scheduler fields

| Field | Type / default | Meaning |
| --- | --- | --- |
| `scheduler.enabled` | Boolean, `true` | Enable proactive signal processing. Disabling it leaves explicit model requests available. |
| `scheduler.pollIntervalMs` | Number, `30000` | Core tick interval; at least 100 ms. |
| `scheduler.defaultCooldownMs` | Number, `1800000` | Default per-rule cooldown, 30 minutes. |
| `scheduler.defaultDedupeWindowMs` | Number, `300000` | Default deduplication window, 5 minutes. |

Durations must be finite and non-negative; configuration values are rounded down to integer milliseconds. Individual rules can override cooldown and deduplication. The built-in rules use their own cooldowns. Rule definitions and examples are in the [CLI reference](cli-reference.md). The Swift idle sampler has its own fixed 30-second interval; changing `pollIntervalMs` does not change that sampler.

## Proactive work-analysis fields

In Settings → Proactive suggestions → **Local work assistant**, choose Ollama or LM Studio, enter the service URL and model ID, or load the service's model list. Defaults are `http://127.0.0.1:11434` and `http://127.0.0.1:1234/v1`. Loopback and private LAN IP addresses are supported; redirects are rejected. An API key is optional. Saving does not verify connectivity: Test connection sends a real request and checks JSON output. Check now rechecks current work while preserving suggestion cooldowns.

Hardware recommendations use physical memory and CPU architecture and never download or select a model automatically. For Apple Silicon, recommended Qwen3 Q4 sizes are 0.6B below 8 GB, 1.7B at 8–15 GB, 4B at 16–23 GB, 8B at 24–63 GB, and 14B at 64 GB or more. Intel recommendations are capped at 4B. Choose a smaller model when other applications need memory. Use the actual ID reported by the service; LM Studio IDs may differ from Ollama tags.

| New field | Default | Meaning |
| --- | --- | --- |
| `proactive.localModel` | `{"provider":"ollama","baseUrl":"http://127.0.0.1:11434","model":""}` | Independent local service; providers are `ollama` and `lmstudio`, with optional `apiKey`. An empty model means unconfigured. |

Remote assistance when needed and automatic conversation/draft creation are always enabled. The selected Pi model is called only when the local model explicitly requests more capability with actionable evidence. Concrete drafts are automatically saved as conversations that can be continued. Routine analysis and synthesis always use the local model first. Missing configuration, connection failure, timeout, or invalid JSON never trigger an automatic remote fallback. The internal `remote_assist` capability sends only relevant fact summaries and the escalation reason to the configured Pi model, with no Skill installation or manual selection. A remote failure does not repeatedly charge for the same findings on subsequent synthesis cycles. Time and idle rules remain local and do not require a model. Background work creates summaries, text drafts, or plans without file, shell, or desktop tools; manually continuing a conversation uses existing interactive capabilities.

Local API keys are stored in the application's configuration with mode `0600` and omitted from status and settings acknowledgements. A blank key preserves a saved key only for the same service. The local work assistant explicitly disables thinking for both Ollama and LM Studio. LM Studio requests use `reasoning_effort: "none"` and request-specific JSON Schemas for analysis, synthesis, and connection tests so reasoning output cannot consume the structured final answer. A response containing only reasoning and no final text is still treated as a failure.


| Field | Default | Meaning |
| --- | ---: | --- |
| `proactive.enabled` | `true` | Enable background collection and analysis; pausing proactive suggestions also stops pending collection. |
| `proactive.workLookbackHours` | `24` | Work context lookback: `24` / `168` / `720` hours, shown as **24h / 7d / 30d** in settings. |
| `proactive.workIntervalMs` | `60000` | Normal work-context interval; collected but unanalyzed content continues in batches spaced by `taskSpacingMs`. |
| `proactive.notificationsIntervalMs` | `60000` | Accessible notification checks every minute. |
| `proactive.synthesisIntervalMs` | `600000` | Fallback synthesis interval; actionable findings schedule the next synthesis immediately, subject to spacing and cooldown. |
| `proactive.suggestionCooldownMs` | `900000` | Minimum interval between proactive suggestions, 15 minutes. |
| `proactive.taskSpacingMs` | `30000` | Minimum spacing between background tasks, 30 seconds. |
| `proactive.collectionTimeoutMs` | `15000` | Swift collection-response timeout. |
| `proactive.taskTimeoutMs` | `90000` | Total subagent or parent-agent timeout. |

Work and notification tasks run separately; fingerprints, notification digests, and suggestion cooldowns survive restarts. Work input covers multiple accessible application windows, current-user process names/parents/working directories/open files, linked project descriptions/recently modified files/Git status, recently used documents in the system index, and accessible local history from Safari, Chrome, Edge, Brave, Chromium, Arc, Vivaldi, and Firefox. **Settings → Proactive suggestions → Work and notifications → Lookback period** offers 24h, 7d, and 30d, defaulting to 24h. Running processes and open windows provide current work context; documents and browsing records use the selected time range.

Each record includes its source, observation time, and `complete` / `truncated` / `metadata-only` status. Missing document or page text is never invented. Browsing records contain titles, URLs, and visit times; pages are not revisited automatically, and private browsing is not read. Collection rotates across applications, their exposed windows, processes, linked projects, and indexed documents without changing focus or taking screenshots. Browser profiles continue through history pages and rotate when the round budget is reached. Per-round time and content budgets allow up to 240 processes, windows from 24 apps, 12 linked projects, 64 indexed documents, and 160 browsing records. The response distributes record slots across sources so a large window list cannot crowd out the other sources. Permissions, undownloaded files, formats, and read budgets can limit coverage; source availability is reported in `coverage`. Work responses contain at most 512000 UTF-16 code units, with at most 24000 per body. Model inputs are split into batches of at most 6000 characters; unfinished batches remain in memory and continue after window changes.

Up to 256 batches of analyzed work summaries and source metadata are retained for at most 30 days and filtered by the selected lookback. Process/window contents from before collection began cannot be reconstructed. Disabling either content-saving option removes these summaries and sources from persisted state. Unchanged content skips model calls; failures back off. Background agents return facts, drafts, and suggestions without file, shell, network, or desktop-execution tools; local collectors perform file reads. Missing Accessibility permission does not block other available sources, while session locking or cancellation discards the current collection. Notifications remain limited to exposed Notification Center text; notification databases are not read.

The active packaged app automatically requests Accessibility once when proactive collection is enabled and unpaused. `UserDefaults.proactiveAccessibilityRequested` records that attempt; macOS remains authoritative about permission. A denial does not trigger repeated prompts. Settings → Proactive suggestions provides a manual authorization action and refreshes permission state when the app becomes active. Background collection does not request Screen Recording, camera, or microphone access. Protected files and browser history remain subject to OS permissions; unavailable sources are reported without bypassing those restrictions.

## What state retains

State includes rules, pause state, proposal states, cooldown timestamps, hashed deduplication keys, history events retained for 30 days by event time without a record-count cap, separate `usageRecords` retained for 186 days (tokens, model, reasoning depth, tool calls, and outcome), and up to 100 completed/ignored proposals in total. Invalid history timestamps are discarded; future events remain stored but are excluded from the activity view until their time arrives, matching usage filtering. Previously truncated events cannot be recovered. Pending, running, snoozed, and failed proposals remain retained. Status events are not added to the history. An interrupted running proposal becomes failed on restart and is not automatically retried.

Separate `activityRecords` retain event IDs, timestamps, kinds (accepted messages or initial suggestions), and optional application names for 186 days. IDs are deduplicated; invalid and future timestamps are discarded. When upgrading a state without this field, existing historical events are migrated without counting reminders again. These statistics contain no conversation text, and deleting a conversation does not remove its event counts.

- `storePrompts=false` removes application names from statistics records and removes `appName`, `prompt`, `context`, and `signal` from persisted history, clears proposal context, and removes rule context. Rule titles/messages and proposal titles/summaries remain; this is not a switch that erases every piece of user text.
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

Activity rows open details with second-level timestamps, application/window, action, reason, input and result, local/remote routing, provider, request path, duration, upstream request ID, reasoning effort, and tokens. New records correlate by `runId`; ambiguous legacy records remain unassociated. Unreported prices and thinking text are never invented. Displayed input tokens include cached input, with cache reads/writes shown separately and never double-counted. Storage preferences also clear new input, result, reason, and related application metadata. Automatically created draft conversations honor the same preferences.
