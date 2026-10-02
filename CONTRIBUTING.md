# Contributing to Another You

**English** | [简体中文](CONTRIBUTING.zh-CN.md)

Contributions to this open-source project are welcome. Use GitHub for development; Gitee provides mirror access and version distribution only.

The GitHub Project keeps its Board view and field configuration only. Do not create task cards or automatically add Issues or pull requests to it. Continue normal Issue and pull request work in the GitHub repository.

## Report a problem or propose a change

Search existing [GitHub Issues](https://github.com/wzz6423/another-you/issues) before opening a report. Include the commit or version, macOS and CPU architecture, Node and Swift versions, launch method, reproduction steps, and expected versus actual behavior. For model failures, name the provider and model without including credentials or private prompts.

Feature requests should describe the user problem and the smallest useful behavior. Follow the [security policy](SECURITY.md) for vulnerabilities and the [code of conduct](CODE_OF_CONDUCT.md) for conduct concerns. Remove personal paths, tokens, and private content from shared logs or screenshots.

## Prepare the workspace

Requirements and first launch are in the [root README](README.md). Run commands below from the repository root:

```bash
make deps
make check
make test
```

The Node tests use local HTTP fixtures; they need no real API key or downloaded model. Swift tests include the real Node sidecar, so install Agent dependencies before running them. Use `make test-agent`, `make test-swift`, or `make test-scripts` for focused checks.

## Keep changes focused

- Read the relevant implementation and reuse existing helpers and patterns before changing it.
- Keep each branch and pull request focused on one goal. Descriptive names such as `fix/sidecar-startup` or `docs/configuration` make that goal clear.
- Explain why behavior changes and keep unrelated cleanup separate.
- Update both language versions when changing a documented behavior, command, setting, or build process. English pages link to English pages; Chinese pages link to Chinese pages.
- Keep model tools disabled unless the change explicitly designs and validates a new permission boundary. A configuration flag alone is not an implemented capability.

## Verify and submit

Describe the problem, final behavior, changed scope, commands run, and results in the pull request. Include failure or skipped-check reasons and any remaining risks. AI-assisted work needs the same code review and independent verification as other contributions.

| Changed area | Relevant verification |
| --- | --- |
| Agent behavior or configuration | `make check` and `make test-agent`; cover the changed privacy, state, or protocol boundary. |
| Swift or JSONL integration | `make test-swift`; manually exercise affected app interactions. |
| Development scripts | `make test-scripts`; run the affected build or lifecycle path on macOS. |
| Website | `make check` and the [browser interaction checks](website/README.md#verification). |
| Documentation only | Check local links, language pairs, examples, and claims against source. Runtime tests are not required solely for prose changes. |

Automated tests do not establish UI quality, real-model compatibility, notification delivery, or distribution readiness. Record the relevant manual checks separately. The current [CI workflow](.github/workflows/ci.yml) is the source of truth for hosted checks; there is no documented PR-label or CI-skip automation.

Before submitting:

```bash
make clean
git diff --check
git status --short
```

Remove temporary reports, logs, fixtures, and custom build outputs that you created. `make clean` preserves `agent-core/node_modules`, `agent-core/.cache/pi`, personal app data, and custom package directories; inspect those separately when relevant. Do not commit build binaries, `.env` files, credentials, private data, or third-party source caches.

See [packaging](docs/releasing.md) for development `.app` output and [architecture](docs/architecture.md) for ownership boundaries.
