# CLI and JSONL protocol

**English** | [简体中文](cli-reference.zh-CN.md)

The [sidecar CLI](../agent-core/src/cli.ts) reads commands from stdin and writes events to stdout, one JSON object per line. It has no HTTP listener or standalone notification command. The native client uses this same protocol.

## Start and stop

With dependencies installed, run from the repository root:

```bash
node --experimental-strip-types agent-core/src/cli.ts --stdio \
  --config "$HOME/Library/Application Support/AnotherYou/config.json"
```

| Argument | Meaning |
| --- | --- |
| `--stdio` | Required. Select JSON Lines mode. |
| `--config PATH` | Optional configuration path; defaults to the platform data directory's `config.json`. |

The CLI restores state, starts enabled scheduling, checks the current time, emits the `app-launched` signal, and publishes `agent.status`. Startup suggestions depend on pause state, existing proposals, and cooldowns. Model availability is not tested at startup.

Send `{"op":"shutdown"}` to stop. EOF, SIGINT, and SIGTERM also stop scheduling and abort an active model request. The process waits for the active task to finish its cleanup. Fatal startup errors go to stderr and exit with code 1; command errors emit `agent.error` and normally leave the process running.

## Command reference

| `op` | Fields | Behavior |
| --- | --- | --- |
| `status` | None | Emit `agent.status`. |
| `prompt` | `requestId`, `prompt` | Emit a request event, then a response or error. |
| `decide` | `suggestionId`, `decision`; optional `snoozeMinutes` | Generate a draft, snooze, or ignore a proposal. |
| `pause` / `resume` | None | Persist pause state; emit scheduler and Agent status. Pause does not cancel an already submitted model request. |
| `signal` | `signal`; optional `now` | Ingest a time, event, or idle signal. |
| `tick` | Optional `now`, `idleForMs` | Restore due snoozed proposals and evaluate time/idle rules. |
| `addRule` | `rule` | Add or replace the rule with the same ID, then persist it. |
| `removeRule` | `ruleId` | Remove a rule and persist the remaining rules; existing proposals remain. |
| `shutdown` | None | Stop scheduling, cancel the active request, and exit. |

`requestId` is a nonempty string of at most 256 characters; use a fresh ID per prompt. IDs already represented by a completed response in retained history are rejected. `prompt` must be nonblank and at most 50,000 characters. A command line may not exceed 1,000,000 characters. Blank lines are ignored; arrays and other non-object JSON values are rejected.

`now` and signal `at` values must be valid date strings; include a timezone when supplying them. `idleForMs` is a finite non-negative number. Omit synthetic timestamps in normal operation and report actual measured idle duration. Scheduling is skipped when disabled or paused, including due snoozes; direct prompts and user decisions remain available.

Only one `prompt` or `decide/execute` model request can run at a time. Another such command immediately receives an error; it is not queued. Status, pause/resume, snooze/ignore, and shutdown remain processable. Requests have a 60-second limit and no implicit retry. There is no cancel-only command or token-delta event in this protocol.

Rule edits and signal/tick commands have no generic acknowledgment event. Query `status` to inspect rule changes; a signal can legitimately produce no suggestion.

## Input examples

Each example below is a complete command line. Enter the next command when appropriate; sending shutdown immediately after a prompt cancels that request.

```jsonl
{"op":"status"}
{"op":"prompt","requestId":"question-001","prompt":"Help me outline one priority for today."}
{"op":"pause"}
{"op":"resume"}
```

Copy a real `payload.suggestionId` from `proactive.suggestion` or an `id` from `agent.status.payload.proposals`. Replace `SUGGESTION_ID` below and choose one decision:

```jsonl
{"op":"decide","suggestionId":"SUGGESTION_ID","decision":"execute"}
{"op":"decide","suggestionId":"SUGGESTION_ID","decision":"later","snoozeMinutes":15}
{"op":"decide","suggestionId":"SUGGESTION_ID","decision":"ignore"}
```

`execute` generates text for review and performs no external action. `later` defaults to 15 minutes and accepts a finite number from 1 to 1440. Due proposals return with the same suggestion ID and a new event ID. `ignore` marks a proposal ignored.

## Rules and signals

| Built-in rule | Trigger | Cooldown |
| --- | --- | --- |
| `welcome` | Event `app-launched` | 24 hours |
| `morning` | Local time `09:00` | 20 hours |
| `idle` | Idle duration at least 900,000 ms (15 minutes) | 2 hours |

The default deduplication window is 300,000 ms. A rule also waits until its existing pending/running/snoozed/failed proposal is resolved. The core polls time every 30 seconds by default; it does not infer idle duration on its own. The Swift host supplies actual idle measurements every 30 seconds.

All rules require `id`, `type`, `title`, and `message`. Optional fields are `enabled` (defaults to `true`), `context`, `cooldownMs`, and `dedupeWindowMs`; rule durations are finite and non-negative. Additional fields depend on type:

| Rule type | Fields | Matching |
| --- | --- | --- |
| `time` | `at` as `HH:mm`; optional `daysOfWeek` array | Match the local minute and optional weekday: Sunday `0` through Saturday `6`. Missed times are not replayed. |
| `event` | `eventName` | Exact match with the signal's `name`. |
| `idle` | `minIdleMs` | Match when measured `idleForMs` meets the threshold. |

An event rule and corresponding input signal:

```jsonl
{"op":"addRule","rule":{"id":"focus-ended","type":"event","eventName":"focus-ended","title":"Take a short break","message":"Would you like a short reset checklist?","cooldownMs":1800000}}
{"op":"signal","signal":{"type":"event","name":"focus-ended","payload":{}}}
{"op":"status"}
```

This example is a caller-supplied event, not a built-in focus-session connector. A signal has `type` and optional `at` and `dedupeKey`; event signals also have `name` and optional `payload`, and idle signals have `idleForMs`. Time signals have no additional required fields. Rule `context` becomes proposal/model context; an event's `payload` is recorded as signal data, not automatically passed as model context.

Rules are stored in `state.json`, not in the configuration schema. `addRule`/`removeRule` persist them. Cooldowns and deduplication also survive restart; deduplication keys are stored as SHA-256 digests. State-storage preferences still apply to rule context and recorded signals.

## Output events

Every event has `id`, `occurredAt` (ISO timestamp), `kind`, `source`, and `payload`. Some events also have `dedupeKey`. Sources are `scheduler`, `agent`, or `system`.

| `kind` | Main payload fields |
| --- | --- |
| `agent.status` | `configPath`, `paused`, `schedulerEnabled`, `model`, `rules`, `proposals`, `history` |
| `scheduler.status` | `running`, and where supplied `paused` |
| `proactive.suggestion` | `suggestionId`, `ruleId`, `title`, `message`, `summary`, `reason`, `createdAt`, `state`, `trigger`, `context`, `signal` |
| `agent.request` | `requestId`, `prompt` |
| `agent.response` | `requestId`, `text`, `model` |
| `proposal.updated` | `suggestionId`, `decision`, `state`; optional `text`, `snoozedUntil` |
| `agent.error` | `message`; when applicable `requestId` or `suggestionId` |

`scheduler.signal` exists in the event type union but is not emitted by the current default command flow. Status is emitted after a model task finishes, including on failure. The model status contains `configured`, `available`, `endpoint`, `model`, and `message`; their meanings are in [configuration](configuration.md).

Use `payload.suggestionId` as the stable suggestion identity. An envelope `id` identifies that individual event, so it must not be used to create a second card when a snoozed suggestion returns. In a status snapshot, each proposal uses `id` and has `ruleId`, `title`, `summary`, `reason`, `createdAt`, `state`, `context`, and optional `text`/`snoozedUntil`.

## Proposal states

| State | Meaning / next action |
| --- | --- |
| `pending` | Awaiting the user's decision. |
| `running` | Draft request active; further decisions are rejected. |
| `completed` | Draft available; repeated decisions are rejected. |
| `snoozed` | Waiting until due; can still be acted on by the user. |
| `ignored` | Dismissed; repeated decisions are rejected. |
| `failed` | Generation failed or was interrupted; the user may retry, snooze, or ignore. |

`execute` emits `running`, then `completed` with text or `failed` with error text. A failure also emits `agent.error`. Clients must use these events or a later status snapshot to determine success. There is no automatic retry after a restart. See [architecture](architecture.md) for the end-to-end flow and [configuration](configuration.md) for persistence limits.
