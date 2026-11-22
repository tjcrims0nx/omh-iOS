# iPad Chat Workspace

**Status:** Development on `rebrand/omh`, proposed in [PR #4](https://github.com/tjcrims0nx/omh-iOS/pull/4). This describes implementation rather than a certified physical-iPad release.

## Design

OMH opens a native, nonblocking Linux startup/progress view. Once the guest is booted and the dashboard and OpenCode servers both answer HTTP, the app transitions to the **OpenCode conversation interface**, hosted in a WKWebView inside `OMHRootViewController`. This is the actual editor/composer, not the previous read-only OMH dashboard with a search field.

The design takes a minimal iPad layout approach: a compact **68-point icon-only native tool rail** in landscape/regular-width windows, a small OMH status and controls bar, and the conversation occupying the remaining space. Tool buttons have labels for VoiceOver. The unnecessary UIKit navigation/back circle is hidden on iPad. Narrow split windows hide the rail. The on-device OMH code and neon styling remain; the DSHIOS screenshot is a visual reference, not source code copied into the project.

## Startup and failures

The native startup screen tracks real guest import/kernel phases, the dashboard and OpenCode server readiness, current log tail, and full diagnostic report. The app does not enter the conversation before both servers are ready. If a service fails, the startup screen retains diagnostics and a retry control where a service can be restarted. The OS launch storyboard must remain static and fast: slow Linux initialization must run after the scene appears.

## Controls and testing

- **Conversation:** central editor UI, including workspace/session selection and prompt composer. Sending a prompt goes through OpenCode, not the old dashboard search API.
- **Tool rail:** workspace, terminal, activity, server log and capabilities. Buttons have accessible labels and remain touch-sized.
- **More menu:** additional app settings and runtime diagnostics.
- **Rotation/Stage Manager:** reflow with available window width; no forced desktop zoom or secondary dashboard pane.

The iPad XCUITest checks that the native startup gate appears (when still booting), waits for the guest to be ready, observes the editor web view and real composer, verifies the status dot reports `ready`, opens the log and checks server-ready output, and tests portrait/landscape behavior. It captures screenshots in the CI artifacts. Inspect exact-head CI and screenshots before merging.

A green simulator run does not prove a physical iPad install, Apple signing, a live provider API call, or correct display at every Stage Manager width.

## Troubleshooting

| Symptom | Action |
| --- | --- |
| Startup remains visible | Inspect boot status and the full dashboard/editor log; retry failed local services |
| Chat view is empty | Inspect guest OpenCode log, local port, WebKit loading and provider setup |
| Prompt cannot send | Verify a workspace/session is selected, the model provider has valid credentials, and the guest web app is connected |
| Tools disappear in narrow windows | Expand the window: the rail is intentionally hidden to prioritize chat |
| App will not install on device | Sign with appropriate Apple identity and provisioning profile, then verify a physical-device install |

See [Build and Verify](BUILD_AND_VERIFY.md) and the [README](../README.md).
