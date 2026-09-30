#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${1:-release}"
if [ -z "${RENAMORPH_MEDIA_BIN:-}" ] && [ ! -x .build/media/bin/ffmpeg ]; then
    bash scripts/build-media.sh
fi
swift build -c "$configuration"
binary_dir="$(swift build -c "$configuration" --show-bin-path)"
mkdir -p dist
bash scripts/build-icon.sh
build_dir="$(mktemp -d "$PWD/dist/.renamorph-build.XXXXXX")"
cleanup() {
    if [ -d "$build_dir/previous.app" ] && [ ! -e "$PWD/dist/Renamorph.app" ]; then
        mv "$build_dir/previous.app" "$PWD/dist/Renamorph.app"
    fi
    rm -rf "$build_dir"
}
trap cleanup EXIT
app_dir="$build_dir/Renamorph.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Helpers" "$app_dir/Contents/Resources"
cp "$binary_dir/Renamorph" "$app_dir/Contents/MacOS/Renamorph"
cp "$binary_dir/RenamorphWorker" "$app_dir/Contents/Helpers/RenamorphWorker"
cp scripts/Info.plist "$app_dir/Contents/Info.plist"
cp assets/AppIcon.icns "$app_dir/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$app_dir/Contents/PkgInfo"
python3 scripts/bundle-media.py "$app_dir"
if [ "$configuration" = release ]; then
    strip -S "$app_dir/Contents/MacOS/Renamorph" "$app_dir/Contents/Helpers/RenamorphWorker"
fi
codesign --force --sign - "$app_dir/Contents/Helpers/RenamorphWorker"
codesign --force --sign - "$app_dir"
codesign --verify --deep --strict "$app_dir"
if [ -e "$PWD/dist/Renamorph.app" ]; then
    mv "$PWD/dist/Renamorph.app" "$build_dir/previous.app"
fi
mv "$app_dir" "$PWD/dist/Renamorph.app"
rm -rf "$build_dir"
echo "Готово: $PWD/dist/Renamorph.app"
