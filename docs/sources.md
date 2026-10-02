# Sources and adoption boundaries

**English** | [简体中文](sources.zh-CN.md)

This page records upstream code and design references. A reference product's features or claims are not evidence that Another You implements them.

## Pi code and locks

The project uses [Pi](https://github.com/earendil-works/pi), the current upstream recorded in [pi-source.lock.json](../agent-core/pi-source.lock.json). The legacy URL recorded there is `badlogic/pi-mono`. This is the Pi coding-agent project, not the unrelated Raspberry Pi disk-cloning tool named clonepi.

| Item | Locked value |
| --- | --- |
| Source repository | `https://github.com/earendil-works/pi.git` |
| Source branch at resolution | `main` |
| Source snapshot commit | `e792ba131ed0495f3ff58a0eb13f20540e344d5c` |
| SDK package versions | `@earendil-works/pi-agent-core`, `@earendil-works/pi-ai`, and `@earendil-works/pi-coding-agent`, all `0.99.2` |
| SDK release commit | `005af57d88ee23b33778f343a9595b32e67ff788` |
| Source lock resolution date | `2026-10-01` |
| Pi license | MIT |

The source snapshot and SDK release commit are different on purpose. [package.json](../agent-core/package.json) selects the running SDK versions; [package-lock.json](../agent-core/package-lock.json) fixes their full dependency tree and integrity values. Fetching the source cache does not replace these dependencies.

The Pi npm packages omit a top-level license text, so the repository retains the SDK release commit's [Pi MIT license](../licenses/Pi-LICENSE) and its [provenance and SHA256](../licenses/Pi.json). Packaging checks the SDK commit, version, and license hash before copying both files to `Contents/Resources/ThirdParty`; it does not depend on a local Pi source cache.

The [Agent package](https://github.com/earendil-works/pi/tree/e792ba131ed0495f3ff58a0eb13f20540e344d5c/packages/agent) provides the agent/session loop; the [AI package](https://github.com/earendil-works/pi/tree/e792ba131ed0495f3ff58a0eb13f20540e344d5c/packages/ai) supplies model calls and stream handling. Another You reads model configuration and authentication through the coding-agent package’s `ModelRuntime` and `SettingsManager`, and supplies its own system prompt and application tools. Its Swift/Node JSONL protocol is its own. [Pi extensions](https://github.com/earendil-works/pi/blob/e792ba131ed0495f3ff58a0eb13f20540e344d5c/packages/coding-agent/docs/extensions.md) are a reference for future controlled customization; user extensions and skills are not loaded by this preview.

## Inspect or update the source lock

Run from the repository root:

```bash
make pi-source
./agent-core/scripts/bootstrap-pi.sh --print
./agent-core/scripts/bootstrap-pi.sh --check
```

`make pi-source` fetches the locked SHA into the ignored `agent-core/.cache/pi`, checks it out with a detached HEAD, and verifies the resulting SHA. `--print` displays the lock without network access. `--check` compares the lock with the remote branch's current head; it can fail after upstream advances even when the local pinned checkout is correct. It does not inspect the local checkout.

If HTTPS Git is unavailable and GitHub SSH is already configured:

```bash
PI_GIT_TRANSPORT=ssh ./agent-core/scripts/bootstrap-pi.sh fetch
```

For an intentional source upgrade, `./agent-core/scripts/bootstrap-pi.sh --refresh` updates only `commit` and `resolvedAt` in the source lock. Run `make pi-source` afterward to fetch that snapshot. Review upstream changes before adoption. Updating the running SDK separately requires reviewing `package.json`, `package-lock.json`, and the SDK fields in the source lock, then running the Agent and Swift integration checks.

`PI_SOURCE_DIR` and `PI_SOURCE_LOCK` can override the cache and lock paths. Keep customized upstream work outside a disposable cache or commit it before changing snapshots. The script does not merge private source changes into the runtime.

## Product references

- [Today](https://today.ai/) and its [product introduction](https://today.ai/articles/blog/what-is-today): concise briefings, editable memory as a design idea, selective proactive participation, and review before external actions.
- [Google Antigravity overview](https://antigravity.google/docs/overview/) and [features](https://antigravity.google/docs/features/): asynchronous work, scheduled work, subagents, artifact review, and permission design as reference ideas. A live visual comparison was not completed during the initial implementation.

Another You currently uses rules, local state, and user-approved text generation. It has no automatic long-term conversation memory or external-action tools. Website graphics and wording belong to this project; reference-site brand assets are not included.

## Engineering and licenses

Zisla's Makefile, bilingual document layout, and CI patterns informed the development entry points: focused checks, minimal workflow permissions, concurrency cancellation, and cleanup. The update and release flows follow Zshell/Zisla's use of Sparkle, with Another You's own configuration, keys, and release assets; other app identities, unrelated platforms, and Project automation are not copied. Another You's Project keeps only its Board view and fields; contribution work remains in repository Issues and pull requests.

Development skills are tools for contributors, not implicitly loaded prompts or permissions in the end user's assistant. Third-party code remains in npm packages, SwiftPM binary dependencies, or the separate source cache and keeps its own license. The project's [MIT license](../LICENSE) does not replace dependency licenses. Bundled Node has its own license; the [packaging script](../scripts/build-app.sh) requires and copies Node's `LICENSE` and also includes Sparkle's license. Sparkle 2.9.4 uses the official SwiftPM archive with its URL and SHA256 pinned in [Package.swift](../macos/AnotherYou/Package.swift).
