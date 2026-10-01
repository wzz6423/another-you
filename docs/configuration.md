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

## General and model fields

| Field | Type / default | Meaning |
| --- | --- | --- |
| `version` | Number, `1` | Only configuration version 1 is supported. |
| `dataDir` | String, platform data directory | Directory containing runtime state. |
| `model.provider` | String, `local` | `local`, `openai-compatible`, or `anthropic`. |
| `model.model` | String, `local-default` | Exact service model name. The default is a placeholder and cannot be used for a request. |
| `model.endpoint` | String, `http://127.0.0.1:11434/v1` for `local` | HTTP(S) base URL. Other providers require an explicit endpoint. |
| `model.apiKeyEnv` | Optional string, unset | Name of an environment variable containing the key; never the key itself. |
| `model.temperature` | Number, `0.2` | Finite value from 0 to 2. |

`local` and `openai-compatible` use Pi's OpenAI Chat Completions path; `anthropic` uses its Messages path. An endpoint containing credentials, a query, or a fragment is rejected. `localhost` is normalized to `127.0.0.1`; a root path becomes `/v1` for non-Anthropic providers. Match the base URL to the service's actual API.

For `local`, the backend accepts loopback hosts (`localhost`, `127.*`, or `::1`). The Swift settings screen is narrower: `localhost`, `127.0.0.1`, or `::1` only. With no `apiKeyEnv`, local requests use a fixed non-secret placeholder key. If `apiKeyEnv` is supplied, its variable must be set. Both other providers always require an explicit key-variable name, including when their endpoint is loopback. `apiKey` and `api_key` fields are rejected; Pi login state and default provider key variables are not loaded automatically.

`model.configured` in status means the model name, endpoint policy, and key reference are valid. `model.available` is `null` before a request, `true` after success, or `false` after failure; invalid configuration also reports `false`. This status belongs to the current sidecar run. Rule suggestions and successful settings saves do not test model availability.

## Privacy and network fields

| Field | Type / default | Meaning |
| --- | --- | --- |
| `privacy.mode` | String, `strict-local` | `strict-local`, `local-first`, or `custom`. The latter two currently use the same explicit remote-host checks. |
| `privacy.allowNetwork` | Boolean, `false` | Allows non-loopback model requests only with the other checks below. `strict-local` forces this to `false`. |
| `privacy.allowedNetworkHosts` | String array, `[]` | Exact hostnames, trimmed and lowercased. No URL scheme, port, path, or wildcard matching. |
| `privacy.storePrompts` | Boolean, `true` | Retain prompt/context/signal content in persisted state. |
| `privacy.storeResponses` | Boolean, `true` | Retain response text in persisted state. |
| `privacy.redactSecrets` | Boolean, `true` | Apply basic credential-pattern redaction when saving state. |

A non-loopback endpoint requires all of: a provider other than `local`, mode `local-first` or `custom`, `allowNetwork=true`, an exact hostname in `allowedNetworkHosts`, and HTTPS. Each fetch rechecks the destination, requires the configured origin, and rejects HTTP redirects. This policy does not control dependency downloads, Git commands, or other processes.

For a deliberately authorized remote OpenAI-compatible service, a configuration can contain the following. `api.example.com` and `REPLACE_WITH_MODEL` are placeholders, not a working service:

```json
{
  "version": 1,
  "model": {
    "provider": "openai-compatible",
    "model": "REPLACE_WITH_MODEL",
    "endpoint": "https://api.example.com/v1",
    "apiKeyEnv": "ANOTHER_YOU_MODEL_KEY",
    "temperature": 0.2
  },
  "privacy": {
    "mode": "local-first",
    "allowNetwork": true,
    "allowedNetworkHosts": ["api.example.com"],
    "storePrompts": false,
    "storeResponses": false,
    "redactSecrets": true
  }
}
```

Set the named key in the actual sidecar process environment without committing it. Apps launched from Finder do not necessarily inherit terminal exports. Requests send the submitted prompt and, for proposals, explicit context to the chosen service; storage settings do not remove them from a live request.

Saving the Swift local-model settings replaces the model section with `local` and temperature `0.2`, removes its key reference, resets privacy to `strict-local`, disables network authorization, empties allowed hosts, and sets `tools.network=false`. Storage preferences survive. Do not expect a manually configured remote model to survive a later save from this UI.

## Tool declarations and native notifications

| Field | Default |
| --- | --- |
| `tools.filesystem` | `false` |
| `tools.shell` | `false` |
| `tools.network` | `false` |
| `tools.calendar` | `false` |
| `tools.notifications` | `true` |

All tool fields are booleans. They declare policy; the current Pi adapter always receives an empty tool list. Setting a field to `true` does not add a connector or an executable model tool. `tools.network` is not the switch for model HTTP requests; those use the model and privacy rules above.

Native notifications are controlled by `AssistantStore`, a separate `UserDefaults` preference, and macOS permission. `tools.notifications` does not enable or disable them. Notifications require a packaged app, user opt-in, an inactive app, and an unpaused suggestion event; delivery still depends on macOS. See the [macOS guide](../macos/AnotherYou/README.md).

## Scheduler fields

| Field | Type / default | Meaning |
| --- | --- | --- |
| `scheduler.enabled` | Boolean, `true` | Enable proactive signal processing. Disabling it leaves explicit model requests available. |
| `scheduler.pollIntervalMs` | Number, `30000` | Core tick interval; at least 100 ms. |
| `scheduler.defaultCooldownMs` | Number, `1800000` | Default per-rule cooldown, 30 minutes. |
| `scheduler.defaultDedupeWindowMs` | Number, `300000` | Default deduplication window, 5 minutes. |

Durations must be finite and non-negative; configuration values are rounded down to integer milliseconds. Individual rules can override cooldown and deduplication. The built-in rules use their own cooldowns. Rule definitions and examples are in the [CLI reference](cli-reference.md). The Swift idle sampler has its own fixed 30-second interval; changing `pollIntervalMs` does not change that sampler.

## What state retains

State includes rules, pause state, proposal states, cooldown timestamps, hashed deduplication keys, up to 200 history events, and up to 100 completed/ignored proposals in total. Pending, running, snoozed, and failed proposals remain retained. Status events are not added to the history. An interrupted running proposal becomes failed on restart and is not automatically retried.

- `storePrompts=false` removes `prompt`, `context`, and `signal` from persisted history, clears proposal context, and removes rule context. Rule titles/messages and proposal titles/summaries remain; this is not a switch that erases every piece of user text.
- `storeResponses=false` removes history and proposal `text` fields.
- If either content-storage switch is off, persisted `agent.error` details are replaced with a generic message. Failed-proposal text is omitted when prompt storage is off, and all proposal text is omitted when response storage is off.
- `redactSecrets=true` masks common `sk-`, GitHub token, Bearer, API-key, password, secret, and token patterns, including recognized nested field names. It cannot identify arbitrary private text.

These controls operate on the saved copy, not the live JSONL stream or in-memory state, and do not erase existing files until a new save occurs. Deduplication keys are SHA-256 digests. State is written through a temporary file and atomic rename with mode `0600`; newly created state directories request `0700`. Swift also writes configuration atomically with `0600` permissions. The app does not encrypt either file. A malformed state file produces an error; preserve it for repair instead of assuming it was reset.

## Environment and build overrides

| Name | Consumer / effect |
| --- | --- |
| `ANOTHER_YOU_DATA_DIR` | Swift host: directory containing `config.json`. Saving local-model settings also sets `dataDir` to that directory. The standalone Node CLI does not read this variable; use `--config` and `dataDir`. |
| `ANOTHER_YOU_AGENT_ROOT` | Swift host: explicit absolute path to `agent-core`; takes precedence over bundle/development lookup. |
| `ANOTHER_YOU_NODE` | Swift host and packaging: explicit Node executable path. It does not select the `npm` executable used for installation. |
| `OUTPUT_DIRECTORY` | Packaging: output directory, default `dist/macos`; `make run`/`make update` use fixed `dist/dev` instead. |
| `BUNDLE_NODE` | Packaging: `0` for machine-provided Node, `1` to copy a compatible self-contained Node; default `0`. |
| `PORT` | `make website`: loopback preview port, default `4173`. |
| `PI_GIT_TRANSPORT` | Source bootstrap: `ssh` selects the configured GitHub SSH transport; default HTTPS. |
| `PI_SOURCE_DIR` | Source bootstrap: override the default `agent-core/.cache/pi`. |
| `PI_SOURCE_LOCK` | Source bootstrap: override the default `agent-core/pi-source.lock.json`. |

Use absolute paths for runtime overrides. An explicit missing Agent or Node path causes an error rather than falling back. The Swift host normally tries bundled resources before development paths or system Node. `ANOTHER_YOU_DATA_DIR` does not relocate the `UserDefaults` notification preference. See [packaging](releasing.md) and [sources](sources.md) for the relevant commands.
