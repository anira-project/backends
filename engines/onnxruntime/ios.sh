#!/usr/bin/env bash
# iOS (onnxruntime): BUILD device + simulator (arm64) static libs from source and combine
# into an .xcframework (no static prebuilt exists). Smoke runs on the simulator. Produces
# dist/<archive>.zip. Requires python build deps + the onnxruntime-src checkout (the CI job
# sets these up / caches the source, mirroring the desktop static build).
#
# Usage: ios.sh <archive-name>   (produces dist/<archive>.zip)
set -euo pipefail
ARCHIVE="${1:?archive name}"
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"

# Device + simulator static builds (full op set, CPU).
bash "$HERE/build-ort.sh" ios      arm64 Release build-ios-device
bash "$HERE/build-ort.sh" ios-sim  arm64 Release build-ios-sim

# Merge each slice's component archives, then create the xcframework.
bash "$ROOT/shared/bundle-static.sh" "$HERE/build-ios-device/Release" dev/libonnxruntime.a
bash "$ROOT/shared/bundle-static.sh" "$HERE/build-ios-sim/Release"    sim/libonnxruntime.a
rm -rf onnxruntime.xcframework
xcodebuild -create-xcframework \
  -library "$PWD/dev/libonnxruntime.a" -headers "$HERE/include" \
  -library "$PWD/sim/libonnxruntime.a" -headers "$HERE/include" \
  -output onnxruntime.xcframework

mkdir -p dist "staging/$ARCHIVE"
cp -R onnxruntime.xcframework "staging/$ARCHIVE/"
( cd "staging/$ARCHIVE" && cmake -E tar cf "$OLDPWD/dist/$ARCHIVE.zip" --format=zip onnxruntime.xcframework )
echo "packaged dist/$ARCHIVE.zip"
