#!/usr/bin/env bash
# Build the guest root filesystem bundled into the OpenMind Harness iOS app:
#   Alpine 3.21 (aarch64) + OpenCode 1.19.6 (official musl arm64 binary)
#
# Everything guest-side runs inside the iSH-ARM64 CLI emulator on macOS, so the
# result is byte-for-byte what the app boots. Output: build/root.tar.gz
#
# Usage: scripts/build-rootfs.sh [--keep-work]
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
ISH_SRC="${ISH_SRC:-$ROOT/ish-arm64}"
ISH_BUILD="${ISH_BUILD:-$ISH_SRC/build-arm64-release}"
WORK="${WORK:-$ROOT/build/rootfs-work}"
OUT="${OUT:-$ROOT/build/root.tar.gz}"
# The harness (opencode.json, skills, plugins, scripts, commands) lives in
# its own repo (tjcrims0nx/openmind-harness) — this repo is the iOS app
# only. The build fetches the harness here when it is missing, so a fresh
# clone of omh-iOS can build straight away. Override with HARNESS_DIR to
# point at a local harness checkout, or HARNESS_REF for a different ref.
HARNESS_REPO="${HARNESS_REPO:-https://github.com/tjcrims0nx/openmind-harness.git}"
HARNESS_REF="${HARNESS_REF:-main}"
HARNESS_DIR="${HARNESS_DIR:-$ROOT/harness}"

ALPINE_VER=3.21
ALPINE_TARBALL="alpine-minirootfs-${ALPINE_VER}.0-aarch64.tar.gz"
ALPINE_URL="https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VER}/releases/aarch64/${ALPINE_TARBALL}"
# Pinned OpenCode release; the musl arm64 build runs on Alpine.
# Verified 2026-11-21: the binary in opencode-linux-arm64-musl.tar.gz is an
# ARM aarch64 ELF with interpreter /lib/ld-musl-aarch64.so.1, needing only
# libstdc++.so.6 + libc.musl-aarch64.so.1 (both in the guest image).
OPENCODE_VERSION="${OPENCODE_VERSION:-1.19.6}"
OPENCODE_TARBALL="opencode-linux-arm64-musl.tar.gz"
OPENCODE_URL="https://github.com/sst/opencode/releases/download/v${OPENCODE_VERSION}/${OPENCODE_TARBALL}"

log() { printf '\033[1;34m==> %s\033[0m\n' "$*"; }
die() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

# The guest node prints this warning on every start; strip it from build logs.
# `sed` deliberately returns success for empty input while `pipefail` still
# propagates a failing emulator command.  The old `grep ... || true` hid guest
# failures and could export a corrupt image as a successful build.
filter() { sed '/expose_wasm/d'; }

ish() {
    # ish <script-on-stdin>; runs /bin/sh inside the fakefs
    "$ISH_BUILD/ish" -f "$WORK/fakefs" /bin/sh 2>&1 | filter
}

[ -x "$ISH_BUILD/ish" ] || die "iSH CLI not built. Run: (cd $ISH_SRC && meson setup build-arm64-release -Dguest_arch=arm64 --buildtype=release && ninja -C build-arm64-release)"
[ -x "$ISH_BUILD/tools/fakefsify" ] || die "fakefsify not built in $ISH_BUILD/tools"

# Fetch the harness when it is missing (a shallow clone of its repo).
if [ ! -f "$HARNESS_DIR/opencode.json" ]; then
    log "Harness not found at $HARNESS_DIR — cloning $HARNESS_REPO ($HARNESS_REF)"
    git clone --depth 1 --branch "$HARNESS_REF" "$HARNESS_REPO" "$HARNESS_DIR" \
        || die "could not clone the harness repo (set HARNESS_DIR to a local checkout instead)"
fi
[ -f "$HARNESS_DIR/opencode.json" ] || die "harness config missing at $HARNESS_DIR/opencode.json"

mkdir -p "$WORK" "$(dirname "$OUT")"
cd "$WORK"

log "Alpine minirootfs"
[ -f "$ALPINE_TARBALL" ] || curl -fsSL -o "$ALPINE_TARBALL" "$ALPINE_URL"

log "OpenCode musl arm64 binary"
[ -f "$OPENCODE_TARBALL" ] || curl -fsSL -o "$OPENCODE_TARBALL" "$OPENCODE_URL"
rm -rf opencode-bin && mkdir opencode-bin
tar --no-same-owner -xzf "$OPENCODE_TARBALL" -C opencode-bin
test -x opencode-bin/opencode

log "Create fakefs"
rm -rf fakefs
"$ISH_BUILD/tools/fakefsify" "$ALPINE_TARBALL" fakefs

log "Guest phase 1: packages"
ish <<'EOF'
set -e
echo "nameserver 8.8.8.8" > /etc/resolv.conf
echo "nameserver 1.1.1.1" >> /etc/resolv.conf
apk update >/dev/null
apk add --no-progress bash git curl openssh-client ca-certificates libstdc++ libgcc nodejs bubblewrap 2>&1 | tail -1
EOF

log "Guest phase 2: install opencode + overlay"
# Assemble one payload tree rooted at / (the opencode binary, the iSH node
# polyfills, our overlay) and stream it into the guest in a single pass.
rm -rf payload && mkdir -p payload/usr/local/bin payload/lib
install -m 0755 opencode-bin/opencode payload/usr/local/bin/opencode
cp "$ISH_SRC"/app/RootfsPatch.bundle/files/lib/*.js payload/lib/
# Record the overlay version so the app does not re-apply (and downgrade) the
# same RootfsPatch files on first launch.
overlay_ver=$(/usr/libexec/PlistBuddy -c 'Print :version' "$ISH_SRC/app/RootfsPatch.bundle/manifest.plist")
mkdir -p payload/ish && printf '%s\n' "$overlay_ver" > payload/ish/overlay-version
cp -R "$ROOT/rootfs/overlay/." payload/
# Git stores generated wrapper scripts as regular text; set executable modes
# explicitly so the iOS Terminal can run all three guest commands.
chmod 0755 payload/usr/local/bin/omh-live payload/usr/local/bin/omh-sandbox-check
find payload -name '._*' -delete
# The harness config is canonical in the openmind-harness repo (the same
# file the Linux and Termux setups install); place it in the guest image
# so the iOS app ships the identical config.
mkdir -p payload/root/.config/opencode
cp "$HARNESS_DIR/opencode.json" payload/root/.config/opencode/opencode.json
# Verify the harness configuration before packaging it. Fail fast rather than
# shipping a mobile app with a missing default provider or incomplete agents.
node - "$HARNESS_DIR/opencode.json" <<'NODE'
const fs = require('fs');
const config = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
if (config.model !== 'google/gemini-3.5-flash-lite') {
  throw new Error('OMH iOS requires the Gemini default from the harness');
}
for (const agent of ['fast', 'reviewer']) {
  if (!config.agent?.[agent]) throw new Error('Missing harness agent: ' + agent);
}
for (const provider of ['google', 'openai', 'anthropic', 'deepseek', 'openrouter', 'custom']) {
  if (!config.provider?.[provider]) throw new Error('Missing harness provider: ' + provider);
}
console.log('OMH iOS: canonical Gemini, agents, and universal providers configured');
NODE
# Keep the runtime and dashboard outside the migrated user config directory.
runtime=payload/usr/local/share/omh-runtime
mkdir -p "$runtime/scripts"
cp -R "$HARNESS_DIR/modules" "$HARNESS_DIR/dashboard" "$runtime/"
cp -R "$HARNESS_DIR/lib" "$runtime/"
cp "$HARNESS_DIR"/scripts/omh-{dashboard,runtime,mcp,daemon,live}.mjs "$runtime/scripts/"
# lib/ must ship too: omh-dashboard.mjs imports ../lib/omh-chat.mjs
# (the chat API added after the old pin), and the guest fails to boot
# without it (ERR_MODULE_NOT_FOUND in run 45511956857).
# Vercel is fully out of the harness (removed in PR #11, project deleted),
# so nothing Vercel is copied here.
# OpenCode reads OPENCODE_CONFIG as the iPad config path. Bundle the full
# verified harness provider/agent config together with our local MCP entry:
# a bare MCP-only override would mask the canonical model on some versions.
node - "$HARNESS_DIR/opencode.json" "$runtime/ipad-opencode.json" <<'NODE'
const fs=require('node:fs');
const config=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
config.mcp={...config.mcp,'omh-runtime':{
  type:'local',
  command:['/usr/bin/node','/usr/local/share/omh-runtime/scripts/omh-mcp.mjs'],
  enabled:true,timeout:10000
}};
if(config.model!=='google/gemini-3.5-flash-lite'||!config.provider?.google)
  throw Error('iPad guest config lost canonical provider/model settings');
fs.writeFileSync(process.argv[3],JSON.stringify(config,null,2)+'\n');
NODE
# The effective user configuration must include the same MCP registration;
# it must remain effective after app restarts instead of being masked by a
# separate OPENCODE_CONFIG override.
cp "$runtime/ipad-opencode.json" payload/root/.config/opencode/opencode.json
# Same for the starter skill (OpenCode's global skills source).
mkdir -p payload/root/.config/opencode/skills
cp -R "$HARNESS_DIR/skills/." payload/root/.config/opencode/skills/
# Same for the guard plugin (OpenCode's plugin discovery directory).
mkdir -p payload/root/.config/opencode/plugins
cp -R "$HARNESS_DIR/plugins/." payload/root/.config/opencode/plugins/
# Same for the delete-env action: the script on the guest PATH (guest
# Terminal) and the /delete-env command (web UI slash menu).
install -m 0755 "$HARNESS_DIR/scripts/delete-env.sh" payload/usr/local/bin/openmind-delete-env
mkdir -p payload/root/.config/opencode/command
cp "$HARNESS_DIR/commands/delete-env.md" payload/root/.config/opencode/command/delete-env.md
# Same for the custom endpoint: the script on the guest PATH (guest
# Terminal) and the /custom-endpoint command (web UI slash menu).
install -m 0755 "$HARNESS_DIR/scripts/set-custom-endpoint.sh" payload/usr/local/bin/openmind-set-custom-endpoint
cp "$HARNESS_DIR/commands/custom-endpoint.md" payload/root/.config/opencode/command/custom-endpoint.md
# Same for Antigravity: the loopback bridge (the antigravity provider in
# opencode.json points at it) and the Google sign-in script (guest Terminal).
# Node.js is installed in the guest image above (apk add nodejs).
install -m 0755 "$HARNESS_DIR/scripts/antigravity-bridge.mjs" payload/usr/local/bin/openmind-antigravity-bridge.mjs
install -m 0755 "$HARNESS_DIR/scripts/antigravity-login.mjs" payload/usr/local/bin/openmind-antigravity-login.mjs
# BSD tar otherwise serialises extended attributes as AppleDouble `._*` files
# when this payload is unpacked by the Linux guest.
COPYFILE_DISABLE=1 tar czf payload.tgz -C payload .
"$ISH_BUILD/ish" -f "$WORK/fakefs" /bin/sh -c 'cd / && tar xzf -' < payload.tgz 2>&1 | filter

log "Guest phase 3: verify opencode boots and serves"
# Part 1 — in-guest: binary runs, config resolves, models present.
ish <<'EOF'
set -e
export HOME=/root
chmod +x /usr/local/bin/opencode /usr/local/bin/opencode-serve /usr/local/bin/opencode-selftest
mkdir -p /root/workspace
opencode --version
node --version
bwrap --version
test -f /usr/local/share/omh-runtime/scripts/omh-live.mjs
node -e 'const c=require("/usr/local/share/omh-runtime/ipad-opencode.json"); if(c.model!=="google/gemini-3.5-flash-lite"||c.mcp?.["omh-runtime"]?.enabled!==true||!c.provider?.google)process.exit(1)'
# Alpine iSH emulates Linux but cannot be assumed to provide namespace mounts.
# This check only records support; failed isolation must not break app startup.
omh-runtime doctor > /tmp/omh-sandbox-diagnostic.json
node -e 'const d=require("/tmp/omh-sandbox-diagnostic.json"); if(d.schema!=="omh.doctor.v1"||d.sandbox.engine!=="bubblewrap"||typeof d.sandbox.verified!=="boolean")process.exit(1); console.log("iPad sandbox verified:",d.sandbox.verified,"reason:",d.sandbox.reason)'

# Print the underlying Bubblewrap stderr when verification fails. A successful
# version probe alone never permits sandbox.exec, and the guest remains
# fail-closed if iSH cannot implement Linux user/mount namespaces.
node <<'NODE'
const fs=require('node:fs');
const {spawnSync}=require('node:child_process');
const d=JSON.parse(fs.readFileSync('/tmp/omh-sandbox-diagnostic.json','utf8'));
if(!d.sandbox.verified) {
  const args=['--die-with-parent','--new-session','--unshare-all',
    '--ro-bind','/usr','/usr','--ro-bind-try','/bin','/bin',
    '--ro-bind-try','/lib','/lib','--ro-bind-try','/lib64','/lib64',
    '--proc','/proc','--dev','/dev','--tmpfs','/tmp',
    '--bind','/root/workspace','/workspace','--chdir','/workspace',
    '--setenv','HOME','/tmp','--setenv','PATH','/usr/bin:/bin',
    '--','sh','-c','test -d /workspace && test ! -e /etc/passwd'];
  const result=spawnSync('bwrap',args,{encoding:'utf8',timeout:5000,maxBuffer:8192});
  console.log('OMH isolation unavailable; sandbox.exec remains blocked.');
  console.log('Bubblewrap probe exit:',result.status,'signal:',result.signal||'none');
  if(result.error)console.log('Bubblewrap spawn error:',result.error.message);
  if(result.stderr)console.log('Bubblewrap stderr:',result.stderr.trim().slice(0,2048));
}
NODE
# Exercise the packaged CLI in a temporary workspace, leaving the shipped workspace clean.
(
  export OMH_WORKSPACE=/tmp/omh-runtime-smoke
  mkdir -p "$OMH_WORKSPACE"
  echo ready > "$OMH_WORKSPACE/check.txt"
  omh-runtime task:add '{"kind":"workspace.read","input":{"path":"check.txt"}}' >/dev/null
  omh-runtime task:run | node -e 'const t=JSON.parse(require("node:fs").readFileSync(0)); if(t.status!=="completed" || t.result.trim()!=="ready") process.exit(1)'
)
node -e 'const c=require("/root/.config/opencode/opencode.json"); if(c.model !== "google/gemini-3.5-flash-lite") { console.error("Expected Gemini default, got",c.model); process.exit(1) }'
node -e 'const c=require("/root/.config/opencode/opencode.json"); if(c.mcp?.["omh-runtime"]?.enabled!==true) {console.error("Missing local OMH MCP bridge");process.exit(1)}'

opencode models | grep -q "google/gemini-3.5-flash-lite"
opencode models | grep -q "experientiallabs/deepseek-v4.1-flash:free"
opencode models | grep -q "antigravity/gemini-3-flash"
echo "guest opencode: $(opencode --version), Gemini default + fallback + antigravity models present"
rm -rf /var/cache/apk/* /tmp/*
EOF

# Part 2 — boot the server in its own emulator session and probe it from the
# host loopback, the same pattern rootfs-test.sh uses for opencode-serve (and the
# same path the iOS app uses: WKWebView + readiness probe hit the forwarded
# loopback port). Probing from inside the guest does not work reliably in the
# CLI emulator — the first build failed here with HTTP 000 after ~35s even
# though the binary runs fine — so the host probe is authoritative.
PORT=4099
"$ISH_BUILD/ish" -f "$WORK/fakefs" /bin/sh -c "OMH_PORT=$PORT /usr/local/bin/opencode-serve" > "$WORK/opencode-serve.log" 2>&1 &
SERVER_ISH_PID=$!
stop_server() {
    kill "$SERVER_ISH_PID" 2>/dev/null || true
    pkill -f "$ISH_BUILD/ish -f $WORK/fakefs" 2>/dev/null || true
    wait "$SERVER_ISH_PID" 2>/dev/null || true
    sleep 1
}
up=0
for _ in $(seq 1 180); do
    sleep 1
    if curl -fs -o "$WORK/opencode-index.html" --max-time 3 "http://127.0.0.1:$PORT/"; then up=1; break; fi
done
echo "host probe of guest opencode web UI on :$PORT: up=$up"
if [ "$up" != 1 ]; then
    echo "--- opencode-serve.log ---"
    cat "$WORK/opencode-serve.log"
    stop_server
    die "guest opencode web UI did not answer on 127.0.0.1:$PORT within 180s"
fi
grep -o '<title>[^<]*</title>' "$WORK/opencode-index.html" | head -1
stop_server
echo "guest opencode serves its web UI on 127.0.0.1:$PORT"

# Distinguish a working dashboard on the host from a working Node runtime
# inside the actual packaged iSH guest. The iPad app invokes this entrypoint.
log "Guest dashboard: boot on loopback and verify runtime API"
DASH_PORT=4177
"$ISH_BUILD/ish" -f "$WORK/fakefs" /bin/sh -c "OMH_PORT=$DASH_PORT /usr/local/bin/omh-dashboard" > "$WORK/omh-dashboard.log" 2>&1 &
DASH_ISH_PID=$!
dashboard_up=0
for _ in $(seq 1 90); do
    sleep 1
    if curl --fail --silent --show-error --output "$WORK/omh-dashboard-state.json" \
        --max-time 2 "http://127.0.0.1:$DASH_PORT/api/state" 2>/dev/null; then
        dashboard_up=1
        break
    fi
done
if [ "$dashboard_up" = 1 ]; then
    if node - "$WORK/omh-dashboard-state.json" <<'NODE'
const fs = require('fs');
const state = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
if (state.version !== 1 || !state.counts) {
  console.error('Guest dashboard returned an invalid runtime state response');
  process.exit(1);
}
console.log('Guest OMH dashboard API ready on port 4177');
NODE
    then
        dashboard_valid=0
    else
        dashboard_valid=1
    fi
else
    dashboard_valid=1
fi
kill "$DASH_ISH_PID" 2>/dev/null || true
pkill -f "$ISH_BUILD/ish -f $WORK/fakefs" 2>/dev/null || true
wait "$DASH_ISH_PID" 2>/dev/null || true
if [ "$dashboard_valid" != 0 ]; then
    echo "--- guest dashboard stderr/stdout ---"
    tail -100 "$WORK/omh-dashboard.log" || true
    die "packaged Linux guest dashboard did not serve a valid /api/state response on port 4177"
fi

log "Export root.tar.gz"
rm -f "$OUT"
"$ISH_BUILD/tools/unfakefsify" fakefs "$OUT"
ls -lh "$OUT"
shasum -a 256 "$OUT" | tee "$OUT.sha256"

if [ "${1:-}" != "--keep-work" ]; then
    rm -rf opencode-bin stage payload payload.tgz
fi
log "Done: $OUT"
