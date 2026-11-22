#!/usr/bin/env bash
# Build the iPad/iPhone icons from the committed official OMH hexagon M mark.
# This is a build-time conversion: keep the original artwork in openmind-harness.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="${HARNESS_DIR:-$ROOT/harness}/dashboard/app-icon.webp"
[ -s "$SOURCE" ] || { echo "Missing canonical OMH icon: $SOURCE" >&2; exit 1; }
command -v sips >/dev/null || { echo "sips (macOS ImageIO) is required to convert app icon" >&2; exit 1; }
ICON="$ROOT/app/DSHAssets.xcassets/DSHAppIcon.appiconset/icon-1024.png"
BRAND="$ROOT/app/DSHAssets.xcassets/OMHBrandMark.imageset/brand.png"
sips -s format png -z 1024 1024 "$SOURCE" --out "$ICON" >/dev/null
sips -s format png -z 512 512 "$SOURCE" --out "$BRAND" >/dev/null
test -s "$ICON" && test -s "$BRAND"
sips -g pixelWidth -g pixelHeight "$ICON" | grep -q 'pixelWidth: 1024'
sips -g pixelWidth -g pixelHeight "$ICON" | grep -q 'pixelHeight: 1024'
echo "iPadOS branding generated from official OpenMind Harness hexagon M icon"
