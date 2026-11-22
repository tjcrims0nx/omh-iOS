# OMH iOS — Third-Party Software and License Notices

OMH iOS is an iOS/iPadOS port of OpenMind Harness. This document identifies third-party components incorporated in or downloaded for the app. Original OMH-specific code and third-party components have distinct copyright holders.

**This document is a notice and inventory, not a replacement license.** The repository's top-level `LICENSE` currently contains the GNU General Public License version 3 (GPL-3.0). Its full text remains authoritative for covered material. New OMH code does not erase obligations associated with reused code.

## Components requiring preserved upstream notices

| Component | Location or distribution | Source | License handling |
| --- | --- | --- | --- |
| iSH-ARM64 Linux emulator | `ish-arm64/` | https://github.com/OpenMinis/ish-arm64 (fork of https://github.com/ish-app/ish) | Preserve upstream copyright, applicable licenses, and source availability; audit embedded notices before release |
| libarchive | `ish-arm64/deps/libarchive/` | Upstream provenance recorded in `ish-arm64/UPSTREAM.md` | Preserve license files and notices shipped with the vendored source |
| libapps / terminal assets | `ish-arm64/deps/libapps/` | Upstream provenance recorded in `ish-arm64/UPSTREAM.md` | Preserve applicable individual package licenses and notices |
| OpenCode | Installed by `scripts/build-rootfs.sh` into the guest image | https://github.com/anomalyco/opencode | Include the license and notices corresponding to the exact pinned release in the distributed image |
| Alpine Linux and packages | Guest root filesystem built by `scripts/build-rootfs.sh` | https://alpinelinux.org/ | Preserve per-package license information and required source/notices |
| Node.js and runtime dependencies | Guest root filesystem | https://nodejs.org/ | Preserve licenses and third-party notices for the actual distributed versions |

## Source provenance

The vendored emulator provenance is recorded in `ish-arm64/UPSTREAM.md`: OpenMinis/ish-arm64 commit `7e100366a4b59557a4a0c4657d0d6115e99d1f5e`; vendored libarchive and libapps snapshots are recorded there too. Do not remove that provenance merely because OMH has its own branding.

## Original OMH work

Newly authored OMH-specific interface, integration and configuration code may carry its own copyright notice, subject to applicable dependencies, contributor rights, and the repository's top-level license. Do not claim ownership of vendored components.

## Release checklist

1. Inventory the exact bundled versions and all nested license files, including guest packages and bundled JavaScript assets.
2. Retain each upstream license and copyright notice verbatim where required; do not rewrite license texts under a new brand.
3. Provide corresponding source code, build information and other materials required by applicable copyleft licenses when distributing an IPA.
4. Check the terms for Apple signing and distribution against applicable copyleft obligations.
5. Recheck this document whenever dependencies or the guest image change.

**Verification status:** This is an initial inventory based on repository build scripts and provenance. It is not a complete legal audit and does not assert that all nested dependency licenses have been verified.
