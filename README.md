# omh-iOS — OpenMind Harness for iOS / iPadOS

The iOS / iPad app that runs the [OpenMind Harness](https://github.com/tjcrims0nx/openmind-harness) (OpenCode) inside an iSH Linux guest on your iPhone or iPad. Same harness, same providers, same config — packaged as an unsigned IPA you sign yourself.

## What lives here

- `app/` — the iOS app (WKWebView + guest launcher + host bridge)
- `ish-arm64/` — the vendored iSH-ARM64 emulator
- `rootfs/` — the guest overlay (launcher, self-test) staged into the image
- `scripts/build-rootfs.sh` — builds the guest image: Alpine 3.21 + OpenCode 1.19.6
- `Makefile` — `emulator`, `rootfs`, `project`, `app`, `install`, `run`, `test`, `archive`
- `.github/workflows/build-ipa.yml` — builds the unsigned IPA on a macOS runner

## The harness comes from its own repo

This repo is the iOS app **only**. The harness itself — `opencode.json`, skills, plugins, scripts, commands — lives in [tjcrims0nx/openmind-harness](https://github.com/tjcrims0nx/openmind-harness) and is the single source of truth. The build fetches it:

Both CI and local builds fetch the exact OMH revision recorded in [harness.rev](harness.rev). Update that file to advance the engine. For development, set `HARNESS_DIR` to a checkout containing the launcher and Python package.

The app opens **OpenMind Chat** in a blue and neon workspace. To connect an OpenAI-compatible provider, open Terminal, run `openmind-set-custom-endpoint`, and restart the harness after saving the URL, model and key. Chat history lasts until the server restarts.

For coding tools and the configured OpenCode providers, use **More → Switch to Coding Workspace**. The app remembers your choice. Use the same menu to return to OpenMind Chat.

## Build

```sh
make emulator   # build the iSH-ARM64 CLI
make rootfs     # build build/root.tar.gz (Alpine + OpenCode + harness config)
make project    # (re)generate DSH.xcodeproj
make app        # unsigned device build (DSH.app)
```

CI builds the unsigned IPA on every manual run (`Build unsigned IPA` workflow) and uploads it as an artifact. Install it on your iPad with your own signing — the bundle id is `app.jackfruit686.openmind-harness`.

## Test it on your iPad

First launch imports the guest image (about a minute on first boot, then
seconds). Work through these in order; what success looks like is in
brackets.

1. **Install** — sign the IPA with your Apple ID and sideload it. Open the
   app. [The app opens; a progress overlay shows the guest starting.]
2. **First boot** — wait for the overlay to clear and OpenMind Chat
   to appear. [The status dot reads `ready` and the chat input is visible.]
3. **Switch to Coding Workspace and sign in with ChatGPT Plus** — open the Terminal (`>_` in the control
   bar) and run `opencode auth login --provider openai --method "ChatGPT Pro/Plus (headless)"`.
   Enter the shown code at `auth.openai.com/codex/device` in Safari.
   [The terminal reports the login succeeded; no key was typed anywhere.]
4. **First prompt** — in the web UI, type `Say only the word ok.` and send.
   [GPT-5 answers `ok` — that is your Plus subscription answering, not API billing.]
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
