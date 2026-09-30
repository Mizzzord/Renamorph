#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
icon_dir="$(mktemp -d "$PWD/.build/Renamorph.XXXXXX.iconset")"
trap 'rm -rf "$icon_dir"' EXIT
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" assets/AppIcon.png --out "$icon_dir/icon_${size}x${size}.png" >/dev/null
    retina=$((size * 2))
    sips -z "$retina" "$retina" assets/AppIcon.png --out "$icon_dir/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$icon_dir" -o assets/AppIcon.icns
