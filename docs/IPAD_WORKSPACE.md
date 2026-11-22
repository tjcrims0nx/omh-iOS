# Native iPad Workspace

**Status:** Development branch `rebrand/omh`, proposed in [PR #4](https://github.com/tjcrims0nx/omh-iOS/pull/4). This describes the code as implemented, not a certified production release.

## Architecture and navigation

On iPad, `OMHSceneDelegate` selects `OMHNativeIPadController` as the home controller; iPhone continues to use `OMHDashboardViewController`. Both are hosted inside native UIKit navigation. The iPad home is **not a web page stretched to tablet dimensions**. Its main controls are a native sidebar and native detail table with an accessible heading and connection indicator.

The iPad sidebar includes Overview, Agent teams, Tasks, Workflows, Skills, Plugins, Trace, Sandbox, Schedules, Workspaces and Memory. Tapping a section reloads the native detail view. The home provides **OpenCode** (editor) and **Web dashboard** (secondary embedded dashboard) actions. Opening the editor starts the shared harness on demand if idle.

The iPad home queries the local dashboard guest at `GET /api/state` once the dashboard harness is ready. Results are rendered as native rows with an empty/waiting state when there is no data. Local runtime availability depends on guest startup and must be verified independently of compilation.

## Layout and multitasking

- The sidebar has a nominal maximum width of **246pt**, and scales toward **32% of available safe-area width** in narrower windows (minimum 140pt in the current implementation).
- The detail pane occupies the remaining safe-area width.
- The detail table header tracks the actual detail table width. This avoids the older fixed 400pt header being clipped in compact Stage Manager windows.
- Selection remains visible after updating the sidebar table.
- Layout follows rotation and window resizing. Some extremely narrow split windows may still require further testing; do not claim every window size is supported without running it.

The **Web dashboard** remains a WKWebView and may itself have CSS breakpoints; its behavior is not evidence that the UIKit home is scaled. On iPhone, the dashboard is the native-shell home and the editor is separately reachable.

## How to verify

Check on an arm64 iPad simulator and, separately, a signed physical iPad installation:

1. Launch the app and confirm a native sidebar with `omh.native.ipad.sidebar` and detail table `omh.native.ipad.content`.
2. Choose **Tasks**. Confirm the selected row, header change, and a meaningful populated/empty message.
3. Wait for the runtime connection indicator to show a successful local connection (or inspect the actual startup error).
4. Rotate between portrait and landscape; confirm both panes and navigation remain usable without horizontal clipping.
5. Resize a Stage Manager window, including a narrower width; confirm the header and sidebar are not clipped and taps remain accessible.
6. Open **Web dashboard**. Check the embedded dashboard loads after guest readiness and still provides interactive controls.
7. Open **OpenCode**, then navigate back; confirm the editor and local runtime work.
8. Capture screenshots and guest/server logs. Verify that all assertions in `OMHUITests` and the relevant CI jobs pass on **the exact commit tested**.

### Known verification limitations

The static `tests/omh-port-validation.test.mjs` suite checks source structure and key expected snippets; it does **not** simulate UIKit layout or confirm what appears on screen. The iPad XCTest smoke suite exercises native navigation plus the secondary dashboard but does not currently constitute a dedicated matrix for multiple Stage Manager window widths. Physical-device installation, signing and long-running guest stability need separate checks.

## Troubleshooting

| Symptom | Inspect |
| --- | --- |
| App never opens | iPad simulator crash logs, app launch diagnostics, Xcode project/entitlements |
| Only web desktop UI appears | Confirm installed commit includes `OMHNativeIPadController` as iPad home |
| “Starting local OMH runtime…” persists | Guest boot logs, `OMHHarness.dashboard` status, local `/api/state` readiness |
| Native pane overlaps or clips | Available safe-area width, rotation, Stage Manager size and table header sizing |
| Web dashboard blank | WebKit navigation error, localhost port readiness, retry control |
| Editor fails to open | Shared harness startup, editor navigation, runtime logs |

See [Build, Test & Release](BUILD_AND_VERIFY.md) and [README](../README.md).
