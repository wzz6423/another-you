# Another You Agent Core

**English** | [简体中文](README.zh-CN.md)

The Node.js 22.19+ runtime for Another You. It communicates with Swift over JSON Lines, owns proactive rules and local state, and calls models through the official Pi SDK. Model requests generate reviewable text with no file, shell, network-browsing, or message-sending tools.

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

A missing configuration uses a loopback endpoint and the placeholder model `local-default`. The model stays unconfigured until an actual model name is supplied. [config.example.json](config.example.json) uses `qwen3:8b` as an example; install a model separately or replace that name with one already available from your service. The runtime does not install models or start a model server.

## Code ownership

| File | Responsibility |
| --- | --- |
| [src/cli.ts](src/cli.ts) | JSONL input, command dispatch, model-request concurrency, shutdown |
| [src/index.ts](src/index.ts) | Suggestions, decisions, pause state, history, default rules |
| [src/scheduler.ts](src/scheduler.ts) | Time/event/idle matching, cooldowns, deduplication |
| [src/pi-adapter.ts](src/pi-adapter.ts) | Pi sessions, endpoint policy, model requests |
| [src/config.ts](src/config.ts) | Defaults, validation, configuration loading and saving |
| [src/state.ts](src/state.ts) | State persistence, content-storage policy, credential redaction |
| [src/events.ts](src/events.ts) | Event envelope and JSONL encoding |

The CLI handles one model request at a time. Status, pause, and shutdown remain responsive while a model is running; a second model request returns an error. Requests have a 60-second limit and no automatic retry. Each request creates a separate Pi session without automatic conversation memory.

## Pi source and SDK

The running dependencies are `@earendil-works/pi-agent-core` and `@earendil-works/pi-ai`, both pinned to **0.99.2**. [package-lock.json](package-lock.json) locks the full npm dependency tree. [pi-source.lock.json](pi-source.lock.json) separately records the upstream source snapshot and SDK release commit.

To inspect the pinned upstream source, run from the repository root:

```bash
make pi-source
./agent-core/scripts/bootstrap-pi.sh --print
```

The checkout is placed at the ignored `agent-core/.cache/pi` with a detached HEAD. It is not compiled into the app or used instead of the npm SDK. See [sources](../docs/sources.md) for lock checks, SSH transport, and deliberate upgrades.

The adapter explicitly constructs a Pi `Agent` with an empty tool list and guarded HTTP fetch. It does not launch the Pi coding CLI or load the user's Pi configuration, extensions, skills, or default provider credentials. It does not configure a telemetry exporter.

## Verification

[Runtime tests](test/runtime.test.ts) exercise the actual Pi SDK against local HTTP fixtures: model calls without tools, host restrictions, redirect rejection, errors, privacy storage, redaction, decisions, restart recovery, JSONL subprocesses, and control commands during a slow request. [Core tests](test/core.test.ts) cover configuration and scheduler behavior. They require no real API key or model download.

These tests establish fixture behavior, not compatibility with every real model service. Verify a configured service with an actual request and record that result separately. Run `make clean` from the repository root to remove known build/test outputs; dependencies and the Pi source cache are retained.

## Further reading

- [Configuration](../docs/configuration.md): endpoint policy, storage, defaults, and environment variables.
- [CLI and JSONL protocol](../docs/cli-reference.md): commands, events, rules, and proposal states.
- [Architecture](../docs/architecture.md): Swift/runtime boundaries and data flow.
- [Contributing](../CONTRIBUTING.md): focused checks and collaboration rules.
