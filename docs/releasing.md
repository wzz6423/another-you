# Packaging and release status

**English** | [简体中文](releasing.zh-CN.md)

Another You is a **0.1.0 development preview** with public source repositories. In-app updates, architecture-specific packaging, GitHub/Gitee publishing, and Homebrew cask generation are implemented; the first public installer and cask have not been published. Development packages use ad-hoc signing and disable online updates. Release packages require project-specific signing configuration.

## Build a development app

Use full Xcode 27+ with the macOS 27+ SDK and Python 3. Default packaging prepares official Node and npm; development checks also need Node.js 22.19+ and npm. The app's deployment target remains macOS 14. From the repository root:

```bash
make build-package
```

[scripts/build-app.sh](../scripts/build-app.sh) builds the Swift executable in Release mode by default using a temporary scratch directory, copies the sidecar source, locked production npm dependencies, and Sparkle 2.9.4, writes `Info.plist`, applies ad-hoc signing, and verifies the bundle. It removes its temporary build directory on exit.

Builds use the full Xcode selected by `DEVELOPER_DIR` or `xcode-select`; an older Xcode or Command Line Tools fails before compilation. The executable records the selected SDK in `LC_BUILD_VERSION`, and packaging checks that field against the active SDK. The macOS 14 deployment target is separate from the linked SDK version.

The default output is `dist/macos/Another You.app`. The script refuses to overwrite an existing app. To preserve an earlier build, choose a new output directory:

```bash
OUTPUT_DIRECTORY="$PWD/dist/review-build" make build-package
```

Packaging installs locked production dependencies using npm from the official Node distribution. It does not read personal `.npmrc` files or copy developer settings, authentication, or browser profiles. The first build may access the public Node, npm, and Playwright download services. Development type checks and tests still require `make deps`.

`make build-package` always uses Release configuration, while retaining ad-hoc signing and disabled online updates by default. See the release workflow below for signing, update metadata, and archives. Direct script calls accept `CONFIGURATION=debug` or `release`, defaulting to `release`.

## Node and architecture

| Variable | Default | Meaning |
| --- | --- | --- |
| `OUTPUT_DIRECTORY` | Repository `dist/macos` | Destination containing `Another You.app`. |
| `BUNDLE_NODE` | `1` | `1` bundles Node, npm, and the background browser; `0` produces a development package that depends on the machine. |
| `ANOTHER_YOU_NODE` | Unset; prepare the pinned official distribution | Optional `bin/node` inside a complete official distribution. |
| `ANOTHER_YOU_RUNTIME_CACHE` | `agent-core/.cache/runtime` | Public runtime download cache; SHA256 is checked again before use. |

The default app includes Node 22.23.3, npm, Pi's locked production dependencies, and Chromium Headless Shell 153.0.8010.12 matching Playwright 1.63.0. The [runtime lock](../scripts/runtime-dependencies.json) and [preparation script](../scripts/prepare-runtime.py) pin versions, public download URLs, and SHA256 for both architectures. Failed builds clean temporary extraction directories. The app's `runtime/manifest.json` records packaged versions.

An existing official Node distribution can be selected explicitly:

```bash
BUNDLE_NODE=1 \
ANOTHER_YOU_NODE="/absolute/path/to/official-node/bin/node" \
OUTPUT_DIRECTORY="$PWD/dist/bundled-review" \
  make build-package
```

The directory must contain `bin/node`, `include/node/node_version.h`, `lib/node_modules/npm`, and its license. A standalone binary plus a license is insufficient. Node's `LICENSE` is read from the distribution or from `ANOTHER_YOU_NODE_LICENSE`. Homebrew Node binaries with external dynamic-library dependencies are rejected. The browser is still prepared from the pinned download. Node, npm, Chromium, Pi, and Sparkle licenses are retained; Pi's SDK commit and license checksum are also included.

Complete apps prefer their bundled Node and browser and ignore development runtime overrides. Missing bundled dependencies produce an error. The sidecar puts its runtime directory first in `PATH` and removes `NODE_OPTIONS`, `NODE_PATH`, and `DYLD_*`. Only `BUNDLE_NODE=0` keeps local Node and installed-browser fallbacks; those development packages are unsuitable for distribution.

`BUILD_ARCH=arm64` or `x86_64` selects the target architecture, defaulting to the build machine. Swift, Node, the browser, and Sparkle must match it. Cross builds use a separate official host-architecture Node to install dependencies without executing the target Node. Packages are separate thin builds, not universal binaries. Xcode, Swift, and Python are build tools and are not required by users of the complete app. Model weights are not included; users configure their own model account or service in the app's model settings.

## Local development lifecycle

| Command | Behavior |
| --- | --- |
| `make build` | Debug Swift executable in `macos/AnotherYou/.build`; no `.app`. |
| `make run` | Build a Debug app and start the workspace-managed instance at `dist/dev/Another You.app`. |
| `make update` | Same local rebuild/restart as `make run`; no Git fetch or pull. |
| `make stop` | Stop the managed development instance and its sidecar. |
| `make build-package` | Package a separate Release `.app` without launching it. |
| `make clean` | Stop the managed instance and remove known build/test outputs. |

`run` and `update` always use Debug configuration with online updates disabled and a fixed development directory, regardless of `OUTPUT_DIRECTORY` or `CONFIGURATION`. The new app is built before the previous managed instance is stopped. [dev-service.sh](../scripts/dev-service.sh) records the PID, process start time, and executable command so an obsolete record does not authorize stopping a different process. Its log is `dist/dev/another-you.log`.

The Debug app is displayed as **Another You Debug** in macOS, uses bundle identifier `com.anotheryou.mac.debug`, and defaults to `~/Library/Application Support/AnotherYouDebug/`. Release retains `com.anotheryou.mac` and `AnotherYou/`. `ANOTHER_YOU_DATA_DIR` still takes precedence. Both configurations record `AnotherYouBuildConfiguration` in `Info.plist`; the bundle filename remains `Another You.app`. Debug also produces `Another You.app.dSYM` to retain line-level debug information after its temporary scratch directory is removed. `update` replaces the app and symbols together, and `clean` removes both.

`make clean` removes the managed app/log, the default `dist/macos/Another You.app` and its `.dSYM`, Swift `.build`, Agent coverage, and development staging files. It keeps `agent-core/node_modules`, `agent-core/.cache/pi`, personal app data, and packages in custom output directories. Remove your own temporary or custom outputs separately after reviewing them.

## Verification

Before proposing a package change:

```bash
make deps
make check
make test
make build-package
codesign --verify --deep --strict "dist/macos/Another You.app"
plutil -lint "dist/macos/Another You.app/Contents/Info.plist"
node scripts/test-bundled-runtime.mjs "dist/macos/Another You.app"
```

`test-bundled-runtime.mjs` checks licenses, dynamic linkage, and signing, then starts the bundled sidecar, npm, file/shell/network tools, and real bundled browser with an empty temporary `HOME` and minimal `PATH`. It fills and clicks a local fixture page and takes a screenshot, then cleans temporary profiles. Repeatable local Pi measurements are available through `node scripts/benchmark-pi.mjs agent-core /absolute/path/to/node`: seven fresh processes each run 100 file-tool loops without network model latency. This benchmark does not establish provider, extension, or complete Swift reimplementation compatibility.

Use a fresh output directory when an app already exists and adjust the inspection paths accordingly. Independently check that the app opens, locates its sidecar and Node, reports its model configuration accurately, handles a real model request, restores decisions on restart, and stops cleanly. Notification checks require the packaged app and user/macOS opt-in. Verify on each intended destination architecture rather than inferring compatibility from the build host.

After verification, run `make clean` and inspect `git status --short` and `git diff --check`. Clean custom package outputs and temporary captures separately. Do not delete the user's application data as part of build cleanup.

## CI artifacts

The current [CI workflow](../.github/workflows/ci.yml) runs for pushes to `main`, pull requests, and manual dispatch. It checks Agent code, Swift and sidecar integration, development lifecycle scripts, website JavaScript, and shell syntax. Its Swift job uses GitHub's `xcode-27` preview runner, verifies Xcode and the linked SDK, builds with `BUNDLE_NODE=1`, validates the bundle, and runs a JSONL status/shutdown smoke check using temporary configuration.

That job archives `Another-You-macOS.zip` and uploads an Actions artifact named `Another-You-macOS-development-${{ runner.arch }}` with seven-day retention. This is an architecture-specific development artifact available subject to repository access and retention; it is not a GitHub Release. The workflow does not verify real-model inference, visual quality, or notification delivery. Consult the actual run for its result rather than treating this description as proof that the latest CI passed.

## Automatic updates

Three settings control automatic checks, downloads, and installation; all start disabled. Installation requires checks and downloads. Disabling checks also disables downloads and installation. Download-only updates install on normal exit through Sparkle. Automatic installation waits for conversation generation, running cards, and pending actions to finish, then installs and restarts. Manual checks do not require automatic checks.

Updates use HTTPS, Ed25519 signatures for the complete feed and archive, and validation before extraction. A feed or download failure retries the configured mirror once. Cancellation, no available update, and installation errors do not trigger mirror fallback. Update requests to GitHub/Gitee are separate from the model endpoint network policy. Development bundles and direct `swift run` disable updates; `make update` remains a local rebuild.

## Signing and release packages

[release/config.json](../release/config.json) has a `null` public key, so release preflight currently refuses to proceed. Before the first release, provision a dedicated Another You Ed25519 key and stable code-signing identity. Commit only the public key; keep the private key and its backup outside the repository. Do not reuse another app's update identity. Both architectures must come from the same clean commit, with an `X.Y.Z` version and an increasing build number.

| Variable | Purpose |
| --- | --- |
| `SPARKLE_BIN` | Absolute directory containing Sparkle 2.9.4 `generate_appcast` and `sign_update`. |
| `SPARKLE_ED_KEY_FILE` | Private update key, file mode `600`, matching the configured public key. |
| `CODE_SIGN_IDENTITY` | Stable signing identity; release packaging rejects ad-hoc `-`. |
| `CODE_SIGN_KEYCHAIN` | Optional signing keychain. |
| `ANOTHER_YOU_NODE` | Official self-contained Node for the target architecture; releases bundle it. |
| `ANOTHER_YOU_NODE_LICENSE` | Optional explicit Node license path when it is not beside the distribution; required for bundled Node. |
| `NOTARYTOOL_PROFILE` | Optional notarization profile, requiring Developer ID Application signing. |

A stable self-signed certificate is not Developer ID or Apple notarization. The manifest records these separately. For initial key creation, the official command is `generate_keys --account another-you`; use the same account for export, set `umask 077` first, and never print or commit the private key.

Set the environment above and the release parameters before running these examples. `--config` precedes the subcommand, and output directories must not already exist:

```bash
python3 scripts/release.py --config release/config.json preflight \
  --version "$RELEASE_VERSION" --build "$RELEASE_BUILD" --arch arm64
python3 scripts/release.py --config release/config.json package \
  --version "$RELEASE_VERSION" --build "$RELEASE_BUILD" --arch arm64 \
  --output "$RELEASE_ARM_DIR"
python3 scripts/release.py --config release/config.json verify \
  --manifest "$RELEASE_ARM_DIR/manifest.json"
```

Use the Intel Node, `--arch x86_64`, and a separate output directory for Intel. Each output contains a versioned ZIP, SHA256, primary/mirror appcasts, and a manifest. Validation covers versions, architectures, frameworks, rpath, code signatures, Ed25519 signatures, and hashes. Development packaging also accepts `APP_VERSION`, `APP_BUILD`, and `BUILD_ARCH`, defaulting to `0.1.0`, `1`, and the host architecture.

## Publishing and Homebrew

The [release skill](../skills/another-you-release/SKILL.md) and [distribution reference](../skills/another-you-release/references/distribution.md) contain current upload commands and recovery steps. Validate manifests and preview the plan first. Explicit publishing uploads and verifies both hosts' versioned assets before switching stable feeds. Gitee's fixed `update-release` holds its mirror feed, whose enclosure points to the Gitee versioned archive. Existing versioned assets cannot be replaced with different hashes.

Generate a cask from the verified architecture manifests:

```bash
python3 scripts/release.py --config release/config.json cask \
  --manifest "$RELEASE_ARM_DIR/manifest.json" \
  --manifest "$RELEASE_INTEL_DIR/manifest.json" \
  --output "$CASK_OUTPUT"
```

The cask uses real archive SHA256 values, architecture URLs, Sparkle livecheck, and `auto_updates true`. Generation does not push the tap. `brew install --cask wzz6423/tap/another-you` becomes usable only after public archives and the tap update are published and verified; that cask is not live yet. Subsequently, `brew upgrade --cask --greedy wzz6423/tap/another-you` includes this self-updating app in Brew upgrades. Brew installations retain the same in-app update settings.

`make test-updater-install` runs real Sparkle upgrades with disposable apps, keys, and a loopback HTTP channel. It covers downloads, automatic restart, delayed installation, and signature rejection, then cleans up. Production client entry points still require HTTPS.

Before release, verify startup on each supported architecture, upgrades from an older version, delayed installation, signature rejection, and Brew installation/upgrades. Tests, package generation, uploads, and installation on a user's machine are separate claims. `make test-release` tests the release flow with temporary fixtures; setting `SPARKLE_BIN` also enables a real Sparkle signing-tool integration test.

Development Issues and pull requests belong on [GitHub](https://github.com/wzz6423/another-you). [Gitee](https://gitee.com/wzz6423/another-you) is reserved for mirror access and version distribution and does not accept Issues or pull requests.
