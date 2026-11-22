#!/usr/bin/env bash
# Release gate: verify the IPA contains the real OMH runtime, not only an OMH label.
set -euo pipefail

IPA="${1:?Usage: scripts/verify-omh-ipa.sh <OpenMind-Harness-unsigned.ipa>}"
test -s "$IPA" || { echo "Missing IPA: $IPA" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if unzip -Z1 "$IPA" | grep -q '^Payload/DSH.app/'; then
  echo "Legacy DSH.app unexpectedly shipped" >&2
  exit 1
fi
unzip -q "$IPA" 'Payload/OMH.app/*' -d "$TMP"
APP="$TMP/Payload/OMH.app"
test -x "$APP/OMH" || { echo "OMH native executable not bundled" >&2; exit 1; }
test -s "$APP/root.tar.gz" || { echo "OMH Linux guest image missing from app" >&2; exit 1; }
if ! tar -tzf "$APP/root.tar.gz" > "$TMP/rootfs-manifest.txt"; then
  echo "Bundled guest image is not a valid tar.gz" >&2
  exit 1
fi

required=(
  usr/local/bin/omh-dashboard
  usr/local/bin/omh-runtime
  usr/local/bin/omh-live
  usr/local/bin/omh-vercel-mcp
  usr/local/bin/omh-sandbox-check
  usr/local/share/omh-runtime/scripts/omh-dashboard.mjs
  usr/local/share/omh-runtime/scripts/omh-runtime.mjs
  usr/local/share/omh-runtime/scripts/omh-mcp.mjs
  usr/local/share/omh-runtime/scripts/omh-live.mjs
  usr/local/share/omh-runtime/scripts/connect-vercel-mcp.mjs
  usr/local/share/omh-runtime/modules/sandbox.mjs
  usr/local/share/omh-runtime/dashboard/index.html
  root/.config/opencode/opencode.json
)
for entry in "${required[@]}"; do
  if ! grep -Fxq "$entry" "$TMP/rootfs-manifest.txt" && ! grep -Fxq "./$entry" "$TMP/rootfs-manifest.txt"; then
    echo "OMH component missing from bundled guest: $entry" >&2
    exit 1
  fi
done

echo "Verified OMH.app includes Linux guest with ${#required[@]} required OMH runtime/MCP/dashboard/sandbox files."
