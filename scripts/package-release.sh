#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
version="${1:?Usage: package-release.sh VERSION}"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo 'Version must contain three numeric components'
    exit 1
fi
app="$PWD/dist/Renamorph.app"
actual_version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app/Contents/Info.plist")"
if [ "$version" != "$actual_version" ]; then
    echo 'Requested version differs from the app bundle'
    exit 1
fi
codesign --verify --deep --strict "$app"
archive="$PWD/dist/Renamorph-$version-macOS-arm64.zip"
image="$PWD/dist/Renamorph-$version-macOS-arm64.dmg"
if [ -e "$archive" ] || [ -e "$image" ]; then
    echo 'Release assets already exist; preserve them or move them before packaging again'
    exit 1
fi
ditto -c -k --sequesterRsrc --keepParent "$app" "$archive"
stage="$(mktemp -d "$PWD/.build/release-image.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
ditto "$app" "$stage/Renamorph.app"
ln -s /Applications "$stage/Applications"
cp LICENSE "$stage/LICENSE.txt"
cp docs/THIRD_PARTY.md "$stage/Third-party-source.txt"
hdiutil create -volname "Renamorph $version" -srcfolder "$stage" -format UDZO -fs HFS+ "$image"
hdiutil verify "$image"
python3 scripts/package-sources.py "$app" "$version"
cd dist
shasum -a 256 "Renamorph-$version-macOS-arm64.zip" "Renamorph-$version-macOS-arm64.dmg" "Renamorph-$version-third-party-sources.tar.gz" > SHA256SUMS
echo "Release assets ready in $PWD"
