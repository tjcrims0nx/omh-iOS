# OpenMind Harness — iOS & iPadOS

**A native iOS/iPadOS home for [OpenMind Harness](https://github.com/tjcrims0nx/openmind-harness), powered by an on-device iSH-ARM64 Linux guest.**

OMH bundles an Alpine guest, the OpenCode editor, a loopback runtime/dashboard, and host-side UIKit navigation. The app uses the **OMH** Xcode project and scheme and produces an **unsigned IPA**; installation on a physical device requires signing.

> **Development status · November 22, 2026:** The original OMH rebrand is merged into `main`. The new **native iPad workspace** and responsive Stage Manager layout are being reviewed in [PR #4](https://github.com/tjcrims0nx/omh-iOS/pull/4) on `rebrand/omh`. A passing build is not a substitute for a passing iPad launch test, screenshot review, or real-device verification. [CI runs](https://github.com/tjcrims0nx/omh-iOS/actions).

## Experience

| Platform | Home screen | Secondary screens |
| --- | --- | --- |
| iPadOS (PR #4 branch) | Native UIKit sidebar + detail pane, displaying data from the local `/api/state` endpoint | **Web dashboard** (diagnostics/compatibility), **OpenCode** editor |
| iOS / iPhone | OMH-branded native navigation shell containing the local WebKit dashboard | **OpenCode** editor |
| Both | Dark navy/cyan OMH branding, on-device guest boot, independent runtime readiness | Activity, logs, capabilities and guest tools via existing editor shell |

The native iPad view has Overview, Agent teams, Tasks, Workflows, Skills, Plugins, Trace, Sandbox, Schedules, Workspaces, and Memory navigation. Its sidebar width adapts to the *available window* rather than assuming a full-screen iPad; the detail header also resizes with the pane. **Native iPad and iPhone UIs are not identical**, and WebKit remains in the secondary web dashboard and editor.

See [iPad Workspace](docs/IPAD_WORKSPACE.md) for controls, layout and limitations.

## Repository layout

| Path | Purpose |
| --- | --- |
| `app/` | First-party UIKit shell, harness startup, bridging, resources, OMH entitlements |
| `ish-arm64/` | Vendored iSH-ARM64 Linux emulator and upstream assets |
| `rootfs/` | Guest overlay, launchers and runtime helpers |
| `scripts/gen-xcode-project.rb` | Generates `OMH.xcodeproj` and shared `OMH` scheme |
| `scripts/build-rootfs.sh` | Builds Alpine 3.21 + OpenCode 1.19.6 guest image |
| `scripts/sync-omh-branding.sh` | Syncs the official OMH branding into native assets |
| `tests/OMHTests/` and `tests/OMHUITests/` | Unit/integration and device-interface tests |
| `.github/workflows/build-ipa.yml` | Port validation, unsigned IPA build, iPad + iPhone simulator jobs |

The harness configuration, skills, plugins and commands are maintained in the separate [openmind-harness](https://github.com/tjcrims0nx/openmind-harness) repository. CI checks out a pinned revision; a local rootfs build fetches the harness if a checkout is not present (or uses `HARNESS_DIR`). The pinned harness revision in the workflow is authoritative for that run.

## Build on macOS

Requirements: Apple Silicon Mac, Xcode with iOS SDK and simulator runtimes, `ruby` + `xcodeproj` gem, Meson/Ninja, LLVM linker (`ld.lld`), Git, network access for the harness and guest dependencies, and signing credentials for on-device installation.

```sh
make emulator
make rootfs
bash scripts/sync-omh-branding.sh
make project
make app
```

`make project` regenerates `OMH.xcodeproj`. `make app` builds `OMH.app` for a device (the Makefile's device build uses configured signing; CI separately disables code signing). The configured bundle identifier is `app.jackfruit686.openmind-harness`, marketing version `1.0.17`, and deployment target **iOS/iPadOS 16.0+ on arm64**. `TARGETED_DEVICE_FAMILY = 1,2`.

For a signed local device build, specify your Apple team and device as needed:

```sh
make install TEAM=YOUR_APPLE_TEAM_ID DEVICE=YOUR_DEVICE_UDID
make run TEAM=YOUR_APPLE_TEAM_ID DEVICE=YOUR_DEVICE_UDID
```

Do not assume the unsigned CI artifact installs directly on an iPad. For the unsigned release artifact, open [Actions → Build unsigned IPA](https://github.com/tjcrims0nx/omh-iOS/actions/workflows/build-ipa.yml), select a run and download `openmind-harness-unsigned-ipa`. Its package should contain `Payload/OMH.app` and the embedded `root.tar.gz`. See [Build, Test & Release](docs/BUILD_AND_VERIFY.md) for the verification gate and signing details.

## Use on iPad

1. Launch OMH; first boot imports the guest image and starts the local runtime.
2. On the native iPad home, choose **Overview**, **Tasks** or another sidebar section; check the runtime connection indicator and populated/empty states.
3. Choose **OpenCode** for the editor. Choose **Web dashboard** for the existing browser-based dashboard; it remains a secondary view.
4. Rotate or resize an iPad Stage Manager window; the UIKit panes should adjust without a zoomed desktop-webpage appearance.
5. For runtime diagnostics, use the existing guest console/terminal and commands such as `omh-runtime status`, `omh-runtime doctor`, and `omh-sandbox-check`.

The iPhone has a different landing screen; the iPad's native sidebar should not be expected on iPhone. Model selection, provider authentication and service availability depend on the bundled harness configuration and credentials, **not** on the iOS app alone. A ChatGPT subscription is not an OpenAI API entitlement.

## Verification and troubleshooting

CI runs **four distinct jobs**: static port validation, unsigned Xcode build/IPA packaging, iPad simulator smoke test, and iPhone simulator smoke test. Review the results **for the exact commit you plan to ship**, including the simulator screenshots and diagnostics. Current UI test entry points include `testHarnessBootsAndShowsWebUI` (iPad) and `testIOSPhoneNativeDashboardAndEditor` (iPhone).

If the app opens but reports **Starting local OMH runtime**, check whether guest boot completed and the loopback endpoint is reachable. If the web dashboard is blank, use the **Web dashboard** retry control and inspect the exported simulator logs. If the display is zoomed, confirm you are running the **native iPad workspace branch** rather than the prior WebKit-first iPad build. An iPad screenshot alone does not prove readiness; verify data/connection and navigation as well.

The bundled Linux `bubblewrap` binary is **not proof of sandbox isolation**. `omh-sandbox-check` must verify namespace/mount functionality on the emulated kernel; if unsupported, sandbox-only tasks fail closed. Optional remote MCP/HTTPS connections require explicit configuration and authentication; the local server listens on loopback by default.

## Licensing and provenance

The top-level license is GPL-3.0. The vendored iSH-ARM64 emulator and dependencies retain their own original copyrights and notices. See [third-party licenses](THIRD_PARTY_LICENSES.md) and `ish-arm64/UPSTREAM.md`. Do not remove upstream attribution when publishing or distributing an IPA.

This app repository was split from [openmind-harness](https://github.com/tjcrims0nx/openmind-harness) on November 21, 2026; the Linux and Termux harness setups remain in that separate repository.
