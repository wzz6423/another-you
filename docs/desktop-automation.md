# Shortcuts, screenshots, and computer interaction

**English** | [简体中文](desktop-automation.zh-CN.md)

## Shortcuts

While the app is running, Settings → Shortcuts lets users record, clear, or restore all global and application shortcut bindings. Recording suspends existing bindings; Escape cancels. Duplicate bindings and operating-system registration conflicts are reported. Global shortcuts stop when the app exits.

| Action | Default |
| --- | --- |
| Quick chat | Command-Shift-Space |
| Capture region | Command-Option-Shift-4 |
| Capture foreground window | Control-Option |
| Capture screen | Command-Option-Shift-3 |
| Send message | Command-Return |
| Open settings | Command-comma |
| Quit | Command-Q |
| Stop current task | Command-period |
| Close quick chat | Escape |

The first four bindings are global. Others apply within the relevant application interface. Quick chat remains available from the menu after clearing its binding.

Press and release Control-Option to capture the current external application window. Pressing another key during the chord cancels capture. This modifier-only global listener requires Accessibility permission and can be remapped; existing custom bindings are preserved.

## Screenshots and application context

Quick chat saves an application snapshot before the floating input takes focus: application identity, the original window ID, text, control tree, and window image. Reads default to this initial snapshot; switching applications, windows, or Spaces while composing or after submission does not replace it. Additional reads can refresh the original application window in the background without following the new foreground application or choosing another window in the original application. A closed window, restarted application, or expired target reference produces an explicit error. A desktop without a locatable window retains only its initial screen image and cannot recapture the user's current desktop in the background. Closing the input releases an unsent snapshot; invoking it again captures a new one. Ordinary messages in the main conversation continue to use live reads.

Use the global shortcuts to attach an application or screen snapshot: Control-Option captures the foreground application window, and the region and screen shortcuts capture their respective targets. Capture remembers the target before opening quick chat and adds a removable attachment preview to the composer. Interactive region capture requires a user selection and supports Escape to cancel. ScreenCaptureKit captures screens and windows.

Grant Screen Recording in the **Computer use** section under **Settings → Computer use**. Accessibility access supplies the target application's window title, text, and actionable controls. Without it, only basic application metadata is available; some apps expose limited context. Missing permissions produce an error rather than bypassing macOS authorization.

Screenshots appear as removable previews in quick chat or the main composer and are sent only with the message. Up to four JPEGs are accepted, with a maximum edge of 1600 pixels and 450KB of raw image data per capture. Images and raw capture context are excluded from activity/state persistence; only the application name may be retained for conversation grouping under the content-storage preferences. Model text responses follow existing storage preferences. A configured remote model receives submitted images/context. The model must support image input; text-only models may reject the request.

## Background browser and computer tools

Computer interaction includes **Computer use (`computer_use`)** and **Browser use (`browser_use`)**, both enabled by default. **Settings → Computer use** provides Screen Recording and Accessibility permission controls. Browser use has no separate toggle or configurable options, so it has no description-only settings section.

In the complete app, `browser_use` launches the bundled Chromium Headless Shell without operating the user's normal browser window or requiring Chrome or Edge. The browser is downloaded and verified at build time, with no runtime download. Source runs and `BUNDLE_NODE=0` development packages use an installed Chrome, Chromium, or Edge, or the executable selected by `ANOTHER_YOU_BROWSER_EXECUTABLE`.

Supported actions include tabs, navigation, text/element snapshots, clicking, filling, keyboard input, select options, scrolling, and screenshots. Snapshots include cross-origin iframes and open Shadow DOM. Each operation refreshes element references; stale references are rejected. Closed Shadow DOM, CAPTCHAs, and website automation restrictions can limit access.

Browsers are isolated by conversation. Login state persists under `browser-sessions/<SHA-256 of conversation ID>/browser-profile` in the application data directory; the default conversation retains `browser-profile`. These profiles are separate from the user's personal Chrome profile, so separate login may be needed. Operations within one conversation are serialized with a default 30-second deadline. Cancellation closes only that conversation's browser and invalidates its queued operations; other conversations continue, and a later request can restart the cancelled browser. Screenshot images remain in memory.

`computer_use` executes through the Swift host. Background mode uses Accessibility actions for pressing controls, setting values, and scrolling, without activating applications or synthesizing global input. Unsupported actions fail explicitly. Target applications may themselves open windows, so invisible operation cannot be guaranteed for every native application.

For real mouse or keyboard input, enable Allow foreground control in the conversation before sending. These actions may change focus. Background mode never silently falls back to foreground input. Stop cancels the model, computer, and browser operations; completed external actions are not undone.

## Protocol and verification

`prompt` accepts `attachments: [{data, mimeType, context?}]` and `allowForeground`. Quick chat also sends `desktopSnapshot: {capturedAt, context, contextError?, image?: {data, mimeType}, mode?, screenshotError?}`; `context` contains `pid`, `targetId`, an available `windowId`, and the AX control tree. Failed captures still supply this object to prevent live fallback. The snapshot is scoped to that model turn and is not carried into later conversation turns. The `computer_use` action `snapshot` returns text and image together; `context`/`screenshot` read them separately. Reads default to the initial content. With `refresh: true`, the native host reads only the original window in the background, forces window capture, and returns `frozen: false` and `invocationCapturedAt`. Refreshed control references replace older references for that target without affecting other conversations. Writes that omit `pid` target the invocation application and carry its target reference. Saved snapshots can be read without a native host; refresh and computer operations still require one. PNG/JPEG only, up to 3,000,000 total base64 characters for attachments; JSONL lines are limited to 4,000,000 characters. The native host sets `ANOTHER_YOU_DESKTOP_HOST=1` to enable native `computer_use` operations.

The sidecar emits transient `desktop.request` events containing `requestId` and `arguments`. The host answers with a `desktopResult` command containing `result` or `error`. `desktop.cancel` cancels the matching operation; late replies are ignored. These events bypass activity persistence. `cancel` with `conversationId` stops that conversation's model and tools; omitting it stops all active requests. Each model HTTP request has a 60-second deadline; the complete tool loop has a 180-second deadline.

- `npm test --prefix agent-core`: real headless Chrome/local HTTP pages, Pi image/native-tool round trips, cancellation, and storage boundaries.
- `swift test --package-path macos/AnotherYou`: shortcut registration/conflicts/recording, Accessibility permissions and stale controls, image compression, deadlines, and cancellation.
- Manually exercise a real `.app` for shortcut recording/activation, permission denial/grant, multiple displays, and target-app behavior. Automated tests do not establish these outcomes.
