#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [ -z "${RENAMORPH_MEDIA_BIN:-}" ]; then
    if [ ! -x .build/media/bin/ffmpeg ]; then bash scripts/build-media.sh; fi
    export RENAMORPH_MEDIA_BIN="$PWD/.build/media/bin"
fi
swift build
binary_dir="$(swift build --show-bin-path)"
export RENAMORPH_WORKER="${RENAMORPH_WORKER:-$binary_dir/RenamorphWorker}"
export RENAMORPH_RECOVERY_PROBE="$binary_dir/RenamorphRecoveryProbe"
testing_plugin="$(xcode-select -p)/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"
if [ -f "$testing_plugin" ]; then
    swift test --disable-xctest -Xswiftc -load-plugin-library -Xswiftc "$testing_plugin" "$@"
else
    swift test --disable-xctest "$@"
fi
