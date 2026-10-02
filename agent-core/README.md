# Another You Agent Core

**English** | [简体中文](README.zh-CN.md)

The Node.js 22.19+ runtime for Another You. It communicates with Swift over JSON Lines, owns proactive rules and local state, and calls models through the official Pi SDK. Interactive requests can use file, shell, network, background-browser, and available native-computer tools, including image attachments.

## Develop the runtime

From the repository root:

```bash
make deps
make check
make test-agent
```

To run the sidecar directly, change to `agent-core`:

```bash
npm start -- --config "$HOME/Library/Application Support/AnotherYou/config.json"
```

Enter one JSON command per line, such as `{"op":"status"}`. Finish with `{"op":"shutdown"}`. For a host consuming stdout directly, use the Node command in the [CLI reference](../docs/cli-reference.md); npm may print its own script banner.

Node strips TypeScript at runtime, so there is no JavaScript build output. `npm run check` performs TypeScript type checking. The CLI writes protocol events to stdout and startup diagnostics to stderr.

Model selection, authentication, custom endpoints, and thinking levels come from Pi. Configure local models in Pi too, then select a model with `/model` and press Ctrl+S to save the default. Another You reads `settings.json`, `models.json`, and `auth.json` from `~/.pi/agent` (or `PI_CODING_AGENT_DIR`). It does not install models or start a model server.

## Code ownership

| File | Responsibility |
| --- | --- |
| [src/cli.ts](src/cli.ts) | JSONL input, command dispatch, model-request concurrency, shutdown |
| [src/index.ts](src/index.ts) | Suggestions, decisions, pause state, history, default rules |
| [src/scheduler.ts](src/scheduler.ts) | Time/event/idle matching, cooldowns, deduplication |
| [src/proactive.ts](src/proactive.ts) | Work/notification collection handoff, subagent analysis, parent synthesis, pacing, and deduplication |
| [src/pi-adapter.ts](src/pi-adapter.ts) | Pi configuration, authentication, sessions, model requests |
| [src/config.ts](src/config.ts) | Defaults, validation, configuration loading and saving |
| [src/state.ts](src/state.ts) | State persistence, content-storage policy, credential redaction |
| [src/events.ts](src/events.ts) | Event envelope and JSONL encoding |

The CLI handles one model request at a time. Status, pause, and shutdown remain responsive while a model is running; a second model request returns an error. Each HTTP request has a 60-second deadline; the full tool loop has a 180-second deadline and supports cancel. Requests include recent successful conversation text from the current process, without automatic retries.

## Pi source and SDK

The running dependencies are `@earendil-works/pi-agent-core`, `@earendil-works/pi-ai`, and `@earendil-works/pi-coding-agent`, all pinned to **0.99.2**. [package-lock.json](package-lock.json) locks the full npm dependency tree. [pi-source.lock.json](pi-source.lock.json) separately records the upstream source snapshot and SDK release commit.

To inspect the pinned upstream source, run from the repository root:

```bash
make pi-source
./agent-core/scripts/bootstrap-pi.sh --print
```

The checkout is placed at the ignored `agent-core/.cache/pi` with a detached HEAD. It is not compiled into the app or used instead of the npm SDK. See [sources](../docs/sources.md) for lock checks, SSH transport, and deliberate upgrades.

The adapter uses Pi `ModelRuntime` and `SettingsManager` for model configuration, authentication, and streaming, and constructs a Pi `Agent` with application tools. It does not launch the Pi coding CLI or load user extensions or skills. It does not configure a telemetry exporter.

## Verification

[Runtime tests](test/runtime.test.ts) exercise the actual Pi SDK against local HTTP fixtures: model calls, errors, privacy storage, redaction, decisions, restart recovery, JSONL subprocesses, and control commands during a slow request. [Proactive tests](test/proactive.test.ts) cover separate task intervals, notification deduplication, subagent/parent roles, foreground preemption, cancellation, backoff, and storage policy. [Pi configuration tests](test/pi-config.test.ts) cover model defaults, authentication, reloads, and invalid configuration. [Core tests](test/core.test.ts) cover application configuration and scheduler behavior. They require no real API key or model download.

These tests establish fixture behavior, not compatibility with every real model service. Verify a configured service with an actual request and record that result separately. Run `make clean` from the repository root to remove known build/test outputs; dependencies and the Pi source cache are retained.

## Further reading

- [Configuration](../docs/configuration.md): Pi models, storage, defaults, and environment variables.
- [CLI and JSONL protocol](../docs/cli-reference.md): commands, events, rules, and proposal states.
- [Architecture](../docs/architecture.md): Swift/runtime boundaries and data flow.
- [Contributing](../CONTRIBUTING.md): focused checks and collaboration rules.

## Shortcuts, screenshots, and background interaction

[Shortcuts, screenshots, and background interaction](../docs/desktop-automation.md) describes browser_use / computer_use, image attachments, cancellation, and background limitations.
