#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
version=9.0.2
archive_sha=8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
command -v pkg-config >/dev/null || { echo 'Install build dependencies: brew install pkgconf x264 lame opus libvorbis libvpx webp dav1d'; exit 1; }
prefix="${RENAMORPH_MEDIA_BUILD_ROOT:-$HOME/.cache/Renamorph/media-$version-$(uname -m)}"
if [[ "$prefix" =~ [[:space:]] ]]; then echo 'RENAMORPH_MEDIA_BUILD_ROOT must not contain whitespace (FFmpeg build limitation)'; exit 1; fi
archive="$PWD/.build/vendor/ffmpeg-$version.tar.xz"
source_dir="$PWD/.build/vendor/ffmpeg-$version"
mkdir -p .build/vendor "$prefix"
if [ -d .build/media ] && [ ! -L .build/media ]; then
    mv .build/media ".build/media-previous-$(date +%s)"
fi
ln -sfn "$prefix" .build/media
if [ ! -f "$archive" ]; then
    curl --fail --location --proto '=https' --tlsv1.2 "https://ffmpeg.org/releases/ffmpeg-$version.tar.xz" -o "$archive.download"
    mv "$archive.download" "$archive"
fi
echo "$archive_sha  $archive" | shasum -a 256 -c -
if [ ! -d "$source_dir" ]; then tar -xf "$archive" -C .build/vendor; fi
pkg_paths=""
include_flags=""
library_flags=""
for library in x264 lame opus libvorbis libvpx webp dav1d; do
    library_prefix="$(brew --prefix "$library")"
    pkg_paths="$library_prefix/lib/pkgconfig:$pkg_paths"
    include_flags="$include_flags -I$library_prefix/include"
    library_flags="$library_flags -L$library_prefix/lib"
done
export PKG_CONFIG_PATH="$pkg_paths${PKG_CONFIG_PATH:-}"
cd "$source_dir"
./configure --prefix="$prefix" --enable-shared --disable-static --enable-gpl \
    --disable-autodetect --enable-zlib --enable-bzlib --disable-network --disable-ffplay --disable-doc --disable-debug \
    --disable-devices --enable-indev=lavfi --enable-libx264 --enable-libmp3lame \
    --enable-libopus --enable-libvorbis --enable-libvpx --enable-libwebp --enable-libdav1d \
    --extra-cflags="-O3 -mmacosx-version-min=14.0$include_flags" \
    --extra-ldflags="-mmacosx-version-min=14.0 -Wl,-headerpad_max_install_names$library_flags" > "$prefix/configure.log" 2>&1
make -j "$(sysctl -n hw.logicalcpu)" > "$prefix/build.log" 2>&1
make install > "$prefix/install.log" 2>&1
mkdir -p "$prefix/share/renamorph"
cp COPYING* LICENSE.md "$prefix/share/renamorph/"
cp ffbuild/config.mak "$prefix/share/renamorph/config.mak"
printf '{"version":"%s","archiveSHA256":"%s","source":"https://ffmpeg.org/releases/ffmpeg-%s.tar.xz","releaseKey":"FCF986EA15E6E293A5644F10B4322F04D67658D8"}\n' "$version" "$archive_sha" "$version" > "$prefix/share/renamorph/source.json"
"$prefix/bin/ffmpeg" -version | head -n 3
echo "Media engine built: $prefix/bin"
