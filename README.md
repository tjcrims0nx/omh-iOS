# OpenMind Harness — iOS & iPadOS

**A native iOS/iPadOS home for [OpenMind Harness](https://github.com/tjcrims0nx/openmind-harness), powered by an on-device iSH-ARM64 Linux guest.**

OMH bundles an Alpine guest, the OpenCode editor, a loopback runtime/dashboard, and host-side UIKit navigation. The app uses the **OMH** Xcode project and scheme and produces an **unsigned IPA**; installation on a physical device requires signing.

> **Development status · November 22, 2026:** The original OMH rebrand is merged into `main`. The new **chat-first iPad workspace** with compact native tools are being reviewed in [PR #4](https://github.com/tjcrims0nx/omh-iOS/pull/4) on `rebrand/omh`. A passing build is not a substitute for a passing iPad launch test, screenshot review, or real-device verification. [CI runs](https://github.com/tjcrims0nx/omh-iOS/actions).

## Experience

| Platform | Home screen | Secondary tools |
| --- | --- | --- |
| iPadOS (PR #4 branch) | **Chat-first OpenCode interface** after a native boot/progress gate, using a compact icon-only tool rail | Terminal, logs, activity, capabilities and settings |
| iOS / iPhone | OMH-branded dashboard shell | OpenCode conversation editor |
| Both | On-device Linux guest, OMH navy/cyan branding, separate dashboard/editor readiness | Runtime diagnostics and guest tools |

The iPad now lands directly in an interactive conversation instead of a search form or read-only task dashboard. The startup screen waits for both local services to answer before revealing the editor. The iPad navigation bar no longer adds a redundant empty back button. The 68pt native tool rail uses accessible icon controls and the conversation area expands to the remaining width.

See [iPad Chat Workspace](docs/IPAD_WORKSPACE.md) for navigation, responsive layout and current verification limits.

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

1. Open OMH and follow the native startup progress. The guest Linux runtime, dashboard, and OpenCode editor start before the chat screen appears.
2. Select a workspace and type your request in the central OpenCode conversation composer. The send action belongs to the OpenCode UI, not the previous OMH workspace-search form.
3. The narrow icon rail opens terminal, activity, logs and capabilities. The top-right More menu holds additional settings and diagnostics.
4. Rotate or resize the iPad; the chat stays primary and the tools rail hides at compact widths.
5. If startup fails, use the startup log and retry action instead of entering a disconnected workspace.

The iPhone retains its existing dashboard-first landing screen until separately redesigned. Model choice, API provider login, and service availability depend on the guest config and credentials. A ChatGPT subscription is not an OpenAI API entitlement.

## Verification and troubleshooting

CI runs **four distinct jobs**: static port validation, unsigned Xcode build/IPA packaging, iPad simulator smoke test, and iPhone simulator smoke test. Review the results **for the exact commit you plan to ship**, including the simulator screenshots and diagnostics. Current UI test entry points include `testHarnessBootsAndShowsWebUI` (iPad) and `testIOSPhoneNativeDashboardAndEditor` (iPhone).

If the app opens but reports **Starting local OMH runtime**, check whether guest boot completed and the loopback endpoint is reachable. If chat stays blank, inspect the OpenCode server log and native startup diagnostics. On a narrow Stage Manager window, the native tool rail hides to prioritize the conversation. An iPad screenshot alone does not prove readiness; verify data/connection and navigation as well.

The bundled Linux `bubblewrap` binary is **not proof of sandbox isolation**. `omh-sandbox-check` must verify namespace/mount functionality on the emulated kernel; if unsupported, sandbox-only tasks fail closed. Optional remote MCP/HTTPS connections require explicit configuration and authentication; the local server listens on loopback by default.

## Licensing and provenance

The top-level license is GPL-3.0. The vendored iSH-ARM64 emulator and dependencies retain their own original copyrights and notices. See [third-party licenses](THIRD_PARTY_LICENSES.md) and `ish-arm64/UPSTREAM.md`. Do not remove upstream attribution when publishing or distributing an IPA.

This app repository was split from [openmind-harness](https://github.com/tjcrims0nx/openmind-harness) on November 21, 2026; the Linux and Termux harness setups remain in that separate repository.
