#!/usr/bin/env bash
# Select an iOS iPhone simulator for the native iPhone smoke test.
set -euo pipefail
if [ -n "${DSH_SIMULATOR_LIST_FILE:-}" ]; then
  list=$(<"$DSH_SIMULATOR_LIST_FILE")
else
  list=$(xcrun simctl list devices available)
fi
name=$(printf '%s\n' "$list" | sed -En 's/^ *(iPhone.*) \([0-9A-Fa-f-]{36}\) \((Booted|Shutdown)\)[[:space:]]*$/\1/p' | head -1)
[ -n "$name" ] || { echo "No available iPhone simulator for iOS UI verification" >&2; exit 1; }
printf '%s\n' "$name"
