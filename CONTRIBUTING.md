# Contributing to Another You

**English** | [简体中文](CONTRIBUTING.zh-CN.md)

Contributions to this open-source project are welcome. Use GitHub for development; Gitee provides mirror access and version distribution only.

The GitHub Project keeps its Board view and field configuration only. Do not create task cards or automatically add Issues or pull requests to it. Continue normal Issue and pull request work in the GitHub repository.

## Report a problem or propose a change

Search existing [GitHub Issues](https://github.com/wzz6423/another-you/issues) before opening a report. Use the [Bug report](.github/ISSUE_TEMPLATE/bug_report.yml) or [Feature request](.github/ISSUE_TEMPLATE/feature_request.yml) form and keep the `[Bug]` or `[Feature]` title prefix followed by a specific summary. Form answers and PR descriptions may be in English or Chinese; keep the generated field headings unchanged.

Bug reports require the Another You version or commit, macOS version and CPU, installation or launch method, reproduction steps, expected behavior, actual behavior, and the submission acknowledgements. Node and Swift versions are optional context for source builds or toolchain failures; model provider and model names are optional context for model failures. Feature requests require a user problem and the smallest useful proposed behavior.

Both forms require one area:

| Area | Managed label |
| --- | --- |
| macOS App | `area:macos` |
| Agent & Models | `area:agent` |
| CI & Build | `area:ci-build` |
| Website | `area:website` |
| Documentation | `area:docs` |

Follow the [security policy](SECURITY.md) for private vulnerability reporting and the [code of conduct](CODE_OF_CONDUCT.md) for conduct concerns. Remove personal paths, tokens, credentials, private prompts, and personal content from shared logs or screenshots.

Issue automation synchronizes the form's `bug` or `enhancement` label and its area label. Missing or invalid metadata adds `needs-more-info` and a comment explaining the fields to correct. Editing the issue updates that comment and removes the label once the form is complete. Use the form fields themselves: comments, code examples, placeholders, and duplicate sections do not satisfy required metadata.

## Prepare the workspace

Requirements and first launch are in the [root README](README.md). Run commands below from the repository root:

```bash
make deps
make check
make test
```

The Node tests use local HTTP fixtures; they need no real API key or downloaded model. Swift tests include the real Node sidecar, so install Agent dependencies before running them. Use `make test-agent`, `make test-swift`, or `make test-scripts` for focused checks.

`make test-agent` and `make test-swift` isolate Pi discovery in a temporary directory and clean it on exit, so tests do not read personal Pi accounts. For a direct filtered test command, use the same entry point: `./scripts/run-isolated-tests.sh ./scripts/xcode-toolchain.sh test --package-path macos/AnotherYou --filter LocalizationTests`.

## Keep changes focused

- Read the relevant implementation and reuse existing helpers and patterns before changing it.
- Keep each branch and pull request focused on one goal. Descriptive names such as `fix/sidecar-startup` or `docs/configuration` make that goal clear.
- Explain why behavior changes and keep unrelated cleanup separate.
- Update both language versions when changing a documented behavior, command, setting, or build process. English pages link to English pages; Chinese pages link to Chinese pages.
- Keep model tools disabled unless the change explicitly designs and validates a new permission boundary. A configuration flag alone is not an implemented capability.

## Pull request format

Git commit titles and bodies must be in English. PR titles use an English Conventional Commit subject, for example `fix(agent): preserve session state on restart` or `ci: validate contribution metadata`. The allowed types are `feat`, `fix`, `docs`, `style`, `refactor`, `perf`, `test`, `chore`, `build`, `ci`, and `revert`. An optional scope uses lowercase letters, digits, and hyphens; an optional `!` marks a breaking change.

Use the [PR template](.github/PULL_REQUEST_TEMPLATE.md) and retain its five headings:

- `Summary`: describe the problem, final behavior, and changed scope.
- `PR Type`: keep exactly one `- Type:` matching the title's type.
- `Validation`: start each check with its own `- Status: passed`, `failed`, or `not run`. Passed and failed checks each require their own non-empty `- Command:` and `- Result:`. A check not run requires its own `- Reason:`. For manual checks, describe the actual steps in `Command`.
- `Risk and Rollback`: provide one non-empty `- Risk:` and `- Rollback:` each.
- `Related Issue`: use a closing reference such as `Closes #123`, `Fixes #123`, or `Resolves #123`, one per line. A full GitHub issue URL is also accepted. Write exactly `None` when there is no related issue.

Required values must be visible text outside comments and code blocks. Duplicate sections or fields, including empty duplicates, are invalid. A `passed` status describes your recorded result; the format check cannot verify that a command was actually run. AI-assisted contributions require the same code review and independent verification as other work; report remaining verification gaps.

Example title: `docs: clarify contribution validation`. Replace this example's checks and results with those you actually performed:

```markdown
## Summary

Clarify which validation details contributors must include in a pull request.

## PR Type

- Type: docs

## Validation

- Status: passed
- Command: git diff --check
- Result: No whitespace errors.

- Status: not run
- Reason: Documentation only; no application behavior changed.

## Risk and Rollback

- Risk: Contribution instructions change; application behavior is unaffected.
- Rollback: Revert this documentation change.

## Related Issue

None
```

PR automation synchronizes the type label, adds `development` for a closing issue reference, and adds `needs-more-info` while metadata is invalid. Its existing feedback comment is updated after edits. These labels do not create GitHub Project cards. [PR Quality](.github/workflows/pr-quality-gates.yml) validates titles and bodies on pull requests, including forks, with read-only repository permissions.

PRs created by GitHub's `dependabot[bot]` account are exempt from the human title/body template and the `needs-more-info` label. Build, test, and security checks still apply. Other contributors use the normal metadata contract.

To check a prepared title and body locally, save them as separate UTF-8 files and run:

```bash
ruby .github/scripts/pr-metadata.rb validate --title-file /tmp/pr-title.txt --body-file /tmp/pr-body.md
ruby .github/scripts/issue-metadata.rb validate --title-file /tmp/issue-title.txt --body-file /tmp/issue-body.md
```

## Verify and submit

Choose verification at the changed boundary and report failures or checks you could not run.

| Changed area | Relevant verification |
| --- | --- |
| Agent behavior or configuration | `make check` and `make test-agent`; cover the changed privacy, state, or protocol boundary. |
| Swift or JSONL integration | `make test-swift`; manually exercise affected app interactions. |
| Development scripts | `make test-scripts`; run the affected build or lifecycle path on macOS. |
| CI, templates, or repository automation | `make check-ci`, `make test-ci`, and `make check-repository`. |
| Website | `make check` and the [browser interaction checks](website/README.md#verification). |
| Documentation only | Check local links, language pairs, examples, and claims against source. Runtime tests are not required solely for prose changes. |

Automated tests do not establish UI quality, real-model compatibility, notification delivery, or distribution readiness. Record the relevant manual checks separately. The [CI workflow](.github/workflows/ci.yml) is the source of truth for hosted build and test checks.

### Hosted checks

| Workflow | Checks |
| --- | --- |
| [CI](.github/workflows/ci.yml) | Agent type checks and tests; Swift/sidecar and Markdown renderer tests; lifecycle and release-tool tests; development app packaging; website syntax and localization tests. |
| [CI Lint](.github/workflows/ci-lint.yml) | actionlint, Ruby syntax, metadata/automation regression tests, repository hygiene, and zizmor security auditing of workflows, local actions, and Dependabot configuration. |
| [PR Quality Gates](.github/workflows/pr-quality-gates.yml) | PR title and body format. |
| [CodeQL](.github/workflows/codeql.yml) | Security and quality analysis for GitHub Actions and JavaScript/TypeScript. |
| [Dependency Review](.github/workflows/dependency-review.yml) | Review dependency changes on pull requests. |
| [Skill CI](.github/workflows/skill-ci.yml) | Project skill metadata, structure, and local references. |

CI selects runtime jobs from the changed paths. Recognized documentation-only changes avoid the Agent, Swift, and website runtime jobs. Agent changes also run the Swift sidecar checks. Native code runs Swift checks; website assets run website checks. CI definitions, build scripts, project skills, the Makefile, unknown paths, or an unavailable comparison run the full runtime suite. The other workflows check their own boundaries separately.

`CI result` has a stable name and verifies that every selected runtime job succeeded and every omitted job was allowed by the path or maintainer gate. A failed gate fails the check. Making a check required for merging is a separate repository setting.

[Dependabot](.github/dependabot.yml) proposes weekly updates for GitHub Actions and the Agent and Markdown renderer npm dependencies. Repository hygiene rejects tracked or staged build artifacts and private configuration. Local CI checks require Ruby and actionlint; `make check-ci` checks syntax, `make test-ci` runs automation tests, and `make check-repository` checks repository hygiene.

### Maintainer skip and unskip commands

A maintainer with current `write`, `maintain`, or `admin` repository permission may post a command in a PR comment after reviewing the change and its validation evidence. Put each command on its own line; a reason may follow a colon:

```text
skip-swift: Native checks completed locally; results and toolchain are recorded in Validation.
```

Use `unskip-swift` to restore that target. Supported short commands are:

| Target | Skip | Restore |
| --- | --- | --- |
| Agent core | `skip-agent` | `unskip-agent` |
| SwiftUI macOS | `skip-swift` | `unskip-swift` |
| Website and scripts | `skip-website` | `unskip-website` |
| CI Lint | `skip-lint` | `unskip-lint` |
| PR Quality Gates | `skip-quality` | `unskip-quality` |
| CodeQL | `skip-codeql` | `unskip-codeql` |
| Dependency Review | `skip-deps` | `unskip-deps` |
| Skill CI | `skip-skills` | `unskip-skills` |

`skip-ci` selects the three runtime targets in CI. `skip-all` selects every target in the [skip manifest](.github/ci-skip.json); `unskip-ci` and `unskip-all` restore those groups. Full workflow names and the aliases declared in the manifest are also accepted. Commands in PR titles, descriptions, comments from bots, quoted text, or code examples do not apply.

Commands apply only to the current PR head. The comment must be created or edited after GitHub has recorded a pull-request workflow run for that head; otherwise, wait for a run and post or edit the command again. A new commit expires older decisions. Commands are replayed in comment update order and then line order, so later skip/unskip commands override earlier ones. Editing or deleting a command recomputes the decision.

Maintainers can also run `gh workflow run ci-skip.yml --repo wzz6423/another-you --field pull-request=123`, replacing `123` with the PR number, to reapply decisions from existing comments. This does not create a new skip directive; author permissions and the current head are checked again.

The [CI Skip workflow](.github/workflows/ci-skip.yml) updates one status comment and the `skip-ci` label. The label records the decision; adding it manually does not grant a skip. A changed decision cancels an affected active run and reruns the actual workflow, where the gate skips only selected targets and other checks execute normally. It does not fabricate a successful check, and an unchanged decision does not repeatedly rerun checks. The gate reads the resolver from the default branch; until the resolver is available there, normal checks run.

The bot saves a pending record for the current commit before canceling and rerunning workflows. Checks run normally if that record cannot be saved. Rerun CI Skip to resume recovery after a partial API failure.

Before submitting:

```bash
git diff --check
git status --short
```

Remove only the temporary reports, logs, fixtures, test processes, and custom build outputs created by your work. `make clean` stops this workspace's managed `dist/dev` app and removes shared build outputs; use it only when those resources belong to your test or a full cleanup was requested. It preserves `agent-core/node_modules`, `agent-core/.cache/pi`, personal app data, and custom package directories. Do not interrupt someone else's running app or remove personal data. Do not commit build binaries, `.env` files, credentials, private data, or third-party source caches.

See [packaging](docs/releasing.md) for development `.app` output and [architecture](docs/architecture.md) for ownership boundaries.
