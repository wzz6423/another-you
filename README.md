# Another You

**English** | [简体中文](README.zh-CN.md)

A private, local-first personal AI assistant for macOS. It suggests a next step at a suitable moment and lets you generate a draft, snooze the suggestion, or ignore it.

SwiftUI provides the native window, menu bar, and settings. A Node sidecar manages rules, local state, and model requests through the official Pi SDK. The app and website currently use Chinese; these project documents are available in both languages.

**Status: 0.1.0 development preview.** The GitHub and Gitee repositories are open source. In-app updates and release tooling are implemented; the first public installer and Homebrew cask have not been published.

## What it does

| Capability | Current behavior |
| --- | --- |
| Proactive suggestions | Rules respond to app launch, local time, and the Mac's actual idle duration, with reasons, cooldowns, and deduplication. |
| Proactive work analysis | By default, accessible work-window content is checked every 5 minutes and accessible notification content every 3 minutes. Subagents analyze changes; a parent agent synthesizes every 10 minutes, with at least a 15-minute suggestion cooldown. |
| User decisions | Generate a reviewable draft, snooze for 15 minutes, ignore, or pause proactive suggestions. Decisions and pause state survive restarts. |
| Model requests | Connect to a local OpenAI-compatible service; explicitly authorized remote services are supported through configuration. |
| Native notifications | Opt in from a packaged `.app`; new suggestions can notify you while the app is inactive and macOS permission is granted. |
| Software updates | Configured release apps support checks, automatic downloads, and installation after the current task finishes; online updates are disabled in development builds. |
| Local records | Keep suggestion states and a bounded activity history, with configurable content storage and basic credential redaction. |

User-triggered screenshots, application context, computer interaction, and an independent headless browser are available; see the [interaction guide](docs/desktop-automation.md) for permissions and limits. Proactive analysis reads only the currently accessible work window and notification-center content through macOS Accessibility; it does not take screenshots or read files, and reports permission or unavailable-source states explicitly. Models also have file, shell, and network tools. Suggestions do not establish model availability. The current process retains the latest 20 successful conversation turns as subsequent context. Calendar, Mail, and Notes have no dedicated connectors.

## Get started

The app runs on macOS 14+. Building from source requires full Xcode 27+ with the macOS 27+ SDK, and Node.js 22.19+ with npm. A compatible local model service and an already installed model are needed for drafting, but not for viewing rule-based suggestions. Python 3 is needed for packaging, release tests, and the website preview.

From the repository root:

```bash
make deps
make run
```

`make run` builds and starts `dist/dev/Another You.app` in Debug mode, displayed as **Another You Debug** in macOS. It uses a separate bundle identifier and `~/Library/Application Support/AnotherYouDebug/` data directory; `ANOTHER_YOU_DATA_DIR` overrides that path. Configure models, including local models, in Pi. Press Ctrl+S in Pi’s `/model` picker to save the default, then click **重新读取 Pi 配置** under **设置 → 模型**. Another You uses Pi’s authentication and model settings directly.

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
| `make build` | Compile the Debug Swift executable without packaging or launching. |
| `make check` | Check TypeScript, website JavaScript, and shell syntax. |
| `make test` | Run Agent, Swift, development-script, and release-tool tests. |
| `make test-release` | Verify release signatures, metadata, and the two-host upload flow. |
| `make build-package` | Package a Release `.app` in `dist/macos` without launching it. |
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

[Shortcuts, screenshots, and background interaction](docs/desktop-automation.md)
