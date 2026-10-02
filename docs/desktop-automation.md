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

The first four bindings are global. Others apply within the relevant application interface. Menu and button actions remain available after clearing a binding.

Press and release Control-Option to capture the current external application window. Pressing another key during the chord cancels capture. This modifier-only global listener requires Accessibility permission and can be remapped; existing custom bindings are preserved.

## Screenshots and application context

Capture a region, application window, or screen from a global shortcut or the conversation's screenshot menu. Global capture remembers the target before opening quick chat; the composer uses the most recent external application. Interactive region capture requires a user selection and supports Escape to cancel. ScreenCaptureKit captures screens and windows.

Grant Screen Recording in Settings → Computer interaction. Accessibility access supplies the target application's window title, text, and actionable controls. Without it, only basic application metadata is available; some apps expose limited context. Missing permissions produce an error rather than bypassing macOS authorization.

Screenshots appear as removable previews in quick chat or the main composer and are sent only with the message. Up to four JPEGs are accepted, with a maximum edge of 1600 pixels and 450KB of raw image data per capture. Images and raw capture context are excluded from activity/state persistence; only the application name may be retained for conversation grouping under the content-storage preferences. Model text responses follow existing storage preferences. A configured remote model receives submitted images/context. The model must support image input; text-only models may reject the request.

## Background browser and computer tools

In the complete app, `browser_use` launches the bundled Chromium Headless Shell without operating the user's normal browser window or requiring Chrome or Edge. The browser is downloaded and verified at build time, with no runtime download. Source runs and `BUNDLE_NODE=0` development packages use an installed Chrome, Chromium, or Edge, or the executable selected by `ANOTHER_YOU_BROWSER_EXECUTABLE`.

Supported actions include tabs, navigation, text/element snapshots, clicking, filling, keyboard input, select options, scrolling, and screenshots. Snapshots include cross-origin iframes and open Shadow DOM. Each operation refreshes element references; stale references are rejected. Closed Shadow DOM, CAPTCHAs, and website automation restrictions can limit access.

Login state persists in `browser-profile` under the application's data directory, separately from the user's personal Chrome profile; a separate login may be needed. Operations are serialized with a default 30-second deadline. Cancellation closes the browser and invalidates queued operations; a later request can restart it. Screenshot images remain in memory.

`computer_use` executes through the Swift host. Background mode uses Accessibility actions for pressing controls, setting values, and scrolling, without activating applications or synthesizing global input. Unsupported actions fail explicitly. Target applications may themselves open windows, so invisible operation cannot be guaranteed for every native application.

For real mouse or keyboard input, enable Allow foreground control in the conversation before sending. These actions may change focus. Background mode never silently falls back to foreground input. Stop cancels the model, computer, and browser operations; completed external actions are not undone.

## Protocol and verification

`prompt` accepts `attachments: [{data, mimeType, context?}]` and `allowForeground`. PNG/JPEG only, up to 3,000,000 total base64 characters; JSONL lines are limited to 4,000,000 characters. The native host sets `ANOTHER_YOU_DESKTOP_HOST=1` to enable `computer_use`.

The sidecar emits transient `desktop.request` events containing `requestId` and `arguments`. The host answers with a `desktopResult` command containing `result` or `error`. `desktop.cancel` cancels the matching operation; late replies are ignored. These events bypass activity persistence. `cancel` stops the active model and tools. Each model HTTP request has a 60-second deadline; the complete tool loop has a 180-second deadline.

- `npm test --prefix agent-core`: real headless Chrome/local HTTP pages, Pi image/native-tool round trips, cancellation, and storage boundaries.
- `swift test --package-path macos/AnotherYou`: shortcut registration/conflicts/recording, Accessibility permissions and stale controls, image compression, deadlines, and cancellation.
- Manually exercise a real `.app` for shortcut recording/activation, permission denial/grant, multiple displays, and target-app behavior. Automated tests do not establish these outcomes.
