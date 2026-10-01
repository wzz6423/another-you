# Packaging and release status

**English** | [简体中文](releasing.zh-CN.md)

Another You currently builds a **0.1.0 development preview**. The package uses ad-hoc signing, not Developer ID signing or notarization. There is no established public Release, installer, or automatic update channel. A successful build, signature check, or CI artifact does not establish distribution readiness.

## Build a development app

Use macOS 14+, Swift 6, Node.js 22.19+, and npm. From the repository root:

```bash
make build-package
```

[scripts/build-app.sh](../scripts/build-app.sh) builds the Swift executable in release mode using a temporary scratch directory, copies the sidecar source and locked production npm dependencies, writes `Info.plist`, applies ad-hoc signing, and verifies the bundle. It removes its temporary build directory on exit.

The default output is `dist/macos/Another You.app`. The script refuses to overwrite an existing app. To preserve an earlier build, choose a new output directory:

```bash
OUTPUT_DIRECTORY="$PWD/dist/review-build" make build-package
```

This command installs production dependencies during packaging; `make deps` is still needed for development type checks and tests. Packaging may access npm even when model privacy is `strict-local`. The script uses `npm` from `PATH`.

## Node and architecture

| Variable | Default | Meaning |
| --- | --- | --- |
| `OUTPUT_DIRECTORY` | Repository `dist/macos` | Destination containing `Another You.app`. |
| `BUNDLE_NODE` | `0` | `0` uses Node from the machine; `1` copies Node into the app. |
| `ANOTHER_YOU_NODE` | `node` resolved from `PATH` | Node executable to validate and, when requested, bundle. |

With `BUNDLE_NODE=0`, the app still requires Node.js 22.19+ on the destination Mac. To make a development bundle carry its runtime, supply a self-contained official macOS Node installation with an architecture matching the Swift build:

```bash
BUNDLE_NODE=1 \
ANOTHER_YOU_NODE="/absolute/path/to/official-node/bin/node" \
OUTPUT_DIRECTORY="$PWD/dist/bundled-review" \
  make build-package
```

Replace the Node path with an existing executable. This command does not download Node or a model. A Homebrew Node that depends on external dynamic libraries is rejected for bundling because copying its executable alone would omit those libraries. A neighboring Node `LICENSE` is copied when present; review third-party licenses before distribution.

The script builds the architecture selected by the current Swift toolchain. There is no universal-binary or Intel/Apple Silicon release matrix. The app does not include model weights, and the model service remains a separate requirement.

## Local development lifecycle

| Command | Behavior |
| --- | --- |
| `make build` | Debug Swift executable in `macos/AnotherYou/.build`; no `.app`. |
| `make run` | Build a fresh app and start the workspace-managed instance at `dist/dev/Another You.app`. |
| `make update` | Same local rebuild/restart as `make run`; no Git fetch or pull. |
| `make stop` | Stop the managed development instance and its sidecar. |
| `make build-package` | Produce a separate package; it does not launch it. |
| `make clean` | Stop the managed instance and remove known build/test outputs. |

`run` and `update` use a fixed development directory, regardless of `OUTPUT_DIRECTORY`. The new app is built before the previous managed instance is stopped. [dev-service.sh](../scripts/dev-service.sh) records the PID, process start time, and executable command so an obsolete record does not authorize stopping a different process. Its log is `dist/dev/another-you.log`.

`make clean` removes the managed app/log, the default `dist/macos/Another You.app`, Swift `.build`, Agent coverage, and development staging files. It keeps `agent-core/node_modules`, `agent-core/.cache/pi`, personal app data, and packages in custom output directories. Remove your own temporary or custom outputs separately after reviewing them.

## Verification

Before proposing a package change:

```bash
make deps
make check
make test
make build-package
codesign --verify --deep --strict "dist/macos/Another You.app"
plutil -lint "dist/macos/Another You.app/Contents/Info.plist"
```

Use a fresh output directory when an app already exists and adjust the inspection paths accordingly. Independently check that the app opens, locates its sidecar and Node, reports its model configuration accurately, handles a real model request, restores decisions on restart, and stops cleanly. Notification checks require the packaged app and user/macOS opt-in. Verify on each intended destination architecture rather than inferring compatibility from the build host.

After verification, run `make clean` and inspect `git status --short` and `git diff --check`. Clean custom package outputs and temporary captures separately. Do not delete the user's application data as part of build cleanup.

## CI artifacts

The current [CI workflow](../.github/workflows/ci.yml) runs for pushes to `main`, pull requests, and manual dispatch. It checks Agent code, Swift and sidecar integration, development lifecycle scripts, website JavaScript, and shell syntax. Its macOS job builds with `BUNDLE_NODE=1`, validates the bundle, and runs a JSONL status/shutdown smoke check using temporary configuration.

That job archives `Another-You-macOS.zip` and uploads an Actions artifact named `Another-You-macOS-development-${{ runner.arch }}` with seven-day retention. This is an architecture-specific development artifact available subject to repository access and retention; it is not a GitHub Release. The workflow does not verify real-model inference, visual quality, or notification delivery. Consult the actual run for its result rather than treating this description as proof that the latest CI passed.

## Work required for distribution

Version `0.1.0`, build `1`, and bundle ID `com.anotheryou.mac` are currently written by the packaging script. A formal release process still needs version management, supported architecture builds, Developer ID signing and notarization, artifact/license review, and installation/upgrade checks on destination Macs. Automatic updates are not implemented.

Development Issues and pull requests belong on [GitHub](https://github.com/wzz6423/another-you). [Gitee](https://gitee.com/wzz6423/another-you) is reserved for mirror access and version distribution and does not accept Issues or pull requests. GitHub-to-Gitee mirroring is configured separately by the repository owner; this project has no release mirroring automation. Zisla's release scripts and update feeds do not apply to Another You.
