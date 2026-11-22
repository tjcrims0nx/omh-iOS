# omh-iOS — OpenMind Harness for iOS / iPadOS

The iOS / iPad app that runs the [OpenMind Harness](https://github.com/tjcrims0nx/openmind-harness) (OpenCode) inside an iSH Linux guest on your iPhone or iPad. The guest image packages the pinned, tested OMH runtime, providers, MCP adapters, dashboard, and Linux-only Bubblewrap diagnostic. It is packaged as an unsigned IPA you sign yourself. Linux isolation is available only if the emulated kernel actually supports Bubblewrap namespace mounts; unsupported iSH kernels fail closed.

## What lives here

- `app/` — the iOS app (WKWebView + guest launcher + host bridge)
- `ish-arm64/` — the vendored iSH-ARM64 emulator
- `rootfs/` — the guest overlay (launcher, self-test) staged into the image
- `scripts/build-rootfs.sh` — builds the guest image: Alpine 3.21 + OpenCode 1.19.6
- `Makefile` — `emulator`, `rootfs`, `project`, `app`, `install`, `run`, `test`, `archive`
- `.github/workflows/build-ipa.yml` — builds the unsigned IPA on a macOS runner

## The harness comes from its own repo

This repo is the iOS app **only**. The harness itself — `opencode.json`, skills, plugins, scripts, commands — lives in [tjcrims0nx/openmind-harness](https://github.com/tjcrims0nx/openmind-harness) and is the single source of truth. The build fetches it:

- **CI:** the workflow checks the harness repo out into `harness/` before building the rootfs.
- **Local:** `scripts/build-rootfs.sh` clones it into `harness/` when it is missing (shallow, `main`). Point `HARNESS_DIR` at a local harness checkout to use that instead, or `HARNESS_REF` for a different ref.

So a fresh clone of this repo builds straight away — it just needs git and network for the one harness fetch.

## Current iPadOS port (November 22, 2026)

The iPadOS rootfs now packages the harness at verified commit `55f62a9`, including the updated dashboard, agent/workflow/task runtime, built-in MCP bridge, opt-in live HTTPS connector and official Vercel OAuth MCP registration helper. The effective guest OpenCode config contains `google/gemini-3.5-flash-lite` and preserves the local OMH MCP registration. User-authorized changes to the persistent config remain visible to OpenCode.

**Linux sandbox:** `bubblewrap` is installed in Alpine. The guest command `omh-sandbox-check` reports whether an actual namespace/mount probe succeeds. iSH is a Linux emulator on iPadOS and may block these kernel features. In that case sandbox tasks refuse execution; installing Bubblewrap must not be mistaken for verified isolation.

**Live/MCP commands in the iPad Terminal:** `omh-runtime status`, `omh-runtime doctor`, `omh-vercel-mcp --dry-run`, `omh-vercel-mcp`, and `omh-live` (requires a strong `OMH_LIVE_TOKEN`; binds loopback only). The hosted Vercel dashboard additionally requires an authenticated HTTPS transport; no inbound remote access is enabled automatically.

**Branding:** The official cobalt cyberpunk hexagon-M image lives in `branding/omh-hexagon.webp` and is converted into the native Xcode app icon and brand mark by `scripts/sync-omh-branding.sh`. The guest dashboard uses the same original artwork.

**Verification:** the GitHub workflow builds the guest rootfs, runs a host-side loopback API probe, compiles an unsigned device IPA using Xcode, then runs an iPad simulator launch/UI test. A successful IPA build does not imply the emulator launched: the separate simulator job must also pass. The build explicitly checks the bundled MCP scripts, sandbox diagnostic, OpenCode model and guest dashboard readiness.

## Build

```sh
make emulator   # build the iSH-ARM64 CLI
make rootfs     # build build/root.tar.gz (Alpine + OpenCode + harness config)
bash scripts/sync-omh-branding.sh  # (macOS) derive Xcode icons from official OMH artwork
make project    # (re)generate DSH.xcodeproj
make app        # unsigned device build (OMH.app)
```

CI builds the unsigned IPA on every manual run (`Build unsigned IPA` workflow) and uploads it as an artifact. Install it on your iPad with your own signing — the bundle id is `app.jackfruit686.openmind-harness`.

## iPad workspace

iPad opens the OpenMind Harness dashboard. Its three-column desktop layout, app icon, search, feature views, runtime inspector and activity panels come directly from the harness repository. The app serves them over loopback inside the Linux guest, using the same workspace state as the runtime CLI and the OpenCode MCP bridge. The dashboard adapts to portrait and narrower window sizes. From the guest terminal, run `omh-runtime status` or `omh-runtime task:list` to inspect the same workspace.

Tap **OpenCode** to open the editor. Tap **Dashboard** in the navigation bar to return. Both views keep their in-memory session while switching. The editor starts on demand. On iPhone the editor opens directly.

In the editor, at 740 points of usable window width, iPad shows a persistent sidebar for Workspace, Terminal, Activity, Server Log and Capabilities. At 1040 points, inspectors open beside the live OpenCode session. Choose Workspace or Done to close an inspector. Narrow windows use the compact toolbar. Resizing and rotating keep the current web session mounted.

## Test it on your iPad

First launch imports the guest image (the initial import can take longer on some devices). Work through these in order; what success looks like is in
brackets.

1. **Install** — sign the IPA with your Apple ID and sideload it. Open the
   app. [The app opens; a progress overlay shows the guest starting.]
2. **First boot** — wait for the overlay to clear and the OpenMind dashboard
   to appear. [Dashboard state connects and Refresh responds. The OpenCode editor is available through its own navigation button.]
3. **Sign in with ChatGPT Plus** — open the Terminal (`>_` in the control
   bar) and run `opencode auth login --provider openai --method "ChatGPT Pro/Plus (headless)"`.
   Enter the shown code at `auth.openai.com/codex/device` in Safari.
   [The terminal reports the login succeeded; no key was typed anywhere.]
4. **First prompt** — in the web UI, type `Say only the word ok.` and send.
   [The selected and authenticated provider answers `ok`. Check model selection and credentials; a ChatGPT subscription does not automatically provide API credits.]
5. **Switch provider mid-session** — open the model picker (top of the UI),
   switch to `experientiallabs/deepseek-v4.1-flash:free`, and ask a
   follow-up in the same session. [The free fallback answers and the
   earlier GPT-5 exchange is still in the session — memory intact.]
6. **Switch model back** — pick `openai/gpt-5` again in the same session
   and ask another question. [GPT-5 answers; the session still holds the
   whole conversation.]
7. **Plan mode** — switch the agent to `plan` and ask it to plan a small
   change before editing. [It explores and writes a plan without editing
   files.]
8. **Sub-agent** — ask the primary agent to use the reviewer subagent on
   your current changes. [A read-only review comes back; nothing is edited.]
9. **Sessions** — leave the app, reopen it, and check the session list.
   [Your session is still there and resumes.]
10. **Rotate the iPad** — turn it to landscape and back, including upside
    down. [The layout follows all four orientations.]

If a step fails, note the exact step and what you saw (a screenshot of the
overlay or the Terminal output helps); the app's Log screen (`≡` menu)
holds the guest and server logs.

## Split history

Split out of [tjcrims0nx/openmind-harness](https://github.com/tjcrims0nx/openmind-harness) on 2026-11-21: the iOS app moved here, the harness stayed there. The harness repo's Linux (`linux-setup.sh`) and Termux (`termux-setup.sh`) setups are unchanged.
