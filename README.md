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

- **CI:** the workflow checks the harness repo out into `harness/` before building the rootfs.
- **Local:** `scripts/build-rootfs.sh` clones it into `harness/` when it is missing (shallow, `main`). Point `HARNESS_DIR` at a local harness checkout to use that instead, or `HARNESS_REF` for a different ref.

So a fresh clone of this repo builds straight away — it just needs git and network for the one harness fetch.

## Build

```sh
make emulator   # build the iSH-ARM64 CLI
make rootfs     # build build/root.tar.gz (Alpine + OpenCode + harness config)
make project    # (re)generate DSH.xcodeproj
make app        # unsigned device build (DSH.app)
```

CI builds the unsigned IPA on every manual run (`Build unsigned IPA` workflow) and uploads it as an artifact. Install it on your iPad with your own signing — the bundle id is `app.jackfruit686.openmind-harness`.

## Split history

Split out of [tjcrims0nx/openmind-harness](https://github.com/tjcrims0nx/openmind-harness) on 2026-11-21: the iOS app moved here, the harness stayed there. The harness repo's Linux (`linux-setup.sh`) and Termux (`termux-setup.sh`) setups are unchanged.
