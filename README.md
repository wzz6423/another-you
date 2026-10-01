# Another You

**English** | [简体中文](README.zh-CN.md)

A private, local-first personal AI assistant for macOS. It suggests a next step at a suitable moment and lets you generate a draft, snooze the suggestion, or ignore it.

SwiftUI provides the native window, menu bar, and settings. A Node sidecar manages rules, local state, and model requests through the official Pi SDK. The app and website currently use Chinese; these project documents are available in both languages.

**Status: 0.1.0 development preview.** The GitHub and Gitee repositories are private and require access. There is no public installer or automatic update channel.

## What it does

| Capability | Current behavior |
| --- | --- |
| Proactive suggestions | Rules respond to app launch, local time, and the Mac's actual idle duration, with reasons, cooldowns, and deduplication. |
| User decisions | Generate a reviewable draft, snooze for 15 minutes, ignore, or pause proactive suggestions. Decisions and pause state survive restarts. |
| Model requests | Connect to a local OpenAI-compatible service; explicitly authorized remote services are supported through configuration. |
| Native notifications | Opt in from a packaged `.app`; new suggestions can notify you while the app is inactive and macOS permission is granted. |
| Local records | Keep suggestion states and a bounded activity history, with configurable content storage and basic credential redaction. |

The preview has no Calendar, Mail, Notes, or screen-content connector. Models have no file, shell, or message-sending tools. A draft does not perform an external action. Suggestions come from rules; their appearance does not prove that a model is available. Each model request is a separate turn, without automatic conversation memory.

## Get started

You need macOS 14+, a Swift 6 toolchain, and Node.js 22.19+ with npm. A compatible local model service and an already installed model are needed for drafting, but not for viewing rule-based suggestions. Python 3 is only needed for the website preview.

From the repository root:

```bash
make deps
make run
```

`make run` builds and starts `dist/dev/Another You.app`. In **设置 → 本地模型**, enter the service address and the exact installed model name, then choose **保存并重新连接**. For Ollama, the usual address is `http://127.0.0.1:11434/v1`; `ollama list` shows installed model names. Another You does not install a model or start its server.

A saved configuration is not a connection test. Submit a prompt or approve a draft to verify your model; failures appear in the app.

```bash
make stop    # Stop the development app started from this workspace
make update  # Rebuild and restart local source; does not run git pull
```

For direct Swift development and notification requirements, see the [macOS guide](macos/AnotherYou/README.md). For model settings, file locations, and environment variables, see [configuration](docs/configuration.md).

## Development commands

Run `make help` for the available targets.

| Command | Purpose |
| --- | --- |
| `make build` | Build the Swift executable. |
| `make check` | Check TypeScript, website JavaScript, and shell syntax. |
| `make test` | Run Agent, Swift, and development-script tests. |
| `make build-package` | Build a separate development `.app` in `dist/macos`. |
| `make website` | Serve the static website at `http://127.0.0.1:4173`. |
| `make pi-source` | Fetch the pinned upstream source into `agent-core/.cache/pi`. |
| `make clean` | Stop the managed development app and remove known build/test outputs. |

`clean` keeps dependencies, the Pi source cache, personal application data, and custom package output directories. The packaging script refuses to overwrite an existing app. See [packaging and release status](docs/releasing.md) for output paths, bundling Node, and CI artifacts.

## Privacy and permissions

The default model endpoint is loopback-only. A remote endpoint requires explicit network permission, an exact allowed hostname, and HTTPS. Build and dependency commands may access npm and GitHub independently of the model policy.

Configuration and state normally live in `~/Library/Application Support/AnotherYou/`. They use local file permissions and configurable storage rules, not application-level encryption. Redaction recognizes common credential patterns; it does not identify every kind of private text. Details are in [configuration](docs/configuration.md) and the [security policy](SECURITY.md).

## Documentation

| Guide | Scope |
| --- | --- |
| [macOS](macos/AnotherYou/README.md) | Native app, settings, notifications, troubleshooting |
| [Agent core](agent-core/README.md) | Runtime development and Pi integration |
| [Website](website/README.md) | Static preview and interaction checks |
| [Configuration](docs/configuration.md) | Model, privacy, scheduler, and environment reference |
| [CLI and JSONL protocol](docs/cli-reference.md) | Commands, events, rules, and proposal states |
| [Architecture](docs/architecture.md) | Data flow and implementation boundaries |
| [Packaging and release status](docs/releasing.md) | Development builds and remaining distribution work |
| [Sources](docs/sources.md) | Upstream locks, licenses, and design references |

## Contributing

Use [GitHub](https://github.com/wzz6423/another-you) for code, Issues, and pull requests. [Gitee](https://gitee.com/wzz6423/another-you) is for mirror access and version distribution; it does not accept Issues or pull requests. The repository owner configures GitHub-to-Gitee mirroring separately.

Read the [contribution guide](CONTRIBUTING.md), [code of conduct](CODE_OF_CONDUCT.md), and [security policy](SECURITY.md) before contributing.

## License

[MIT](LICENSE). Third-party dependencies retain their own licenses; see [sources](docs/sources.md).
