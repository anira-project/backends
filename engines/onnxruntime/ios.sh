#!/usr/bin/env bash
# iOS (onnxruntime): BUILD device + simulator (arm64) static libs from source and combine
# into an .xcframework (no static prebuilt exists). Smoke runs on the simulator. Produces
# dist/<archive>.zip. Requires python build deps + the onnxruntime-src checkout (the CI job
# sets these up / caches the source, mirroring the desktop static build).
#
# Usage: ios.sh <archive-name> [variant]   (produces dist/<archive>.zip)
#   [variant]  "" (CPU default) | gpu (CoreML EP compiled in — consumers add
#              CoreML.framework; the CoreML provider header ships only in this variant)
set -euo pipefail
ARCHIVE="${1:?archive name}"; VARIANT="${2:-}"
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"

ACCEL=none; TAG=""
if [ "$VARIANT" = "gpu" ]; then ACCEL=coreml; TAG="-gpu"; fi

# Same header curation as desktop stage.sh: the CoreML provider header only ships in
# packages that actually contain the EP (that's how the smoke/anira detect it).
HDRS="$PWD/xc-headers$TAG"; rm -rf "$HDRS"; mkdir -p "$HDRS"
for h in "$HERE"/include/*.h; do
  [ "$(basename "$h")" = "coreml_provider_factory.h" ] && [ "$VARIANT" != "gpu" ] && continue
  cp "$h" "$HDRS/"
done

# Device + simulator static builds (full op set; CoreML EP added in the gpu variant).
bash "$HERE/build-ort.sh" ios      arm64 Release "$HERE/build-ios-device$TAG" static "$ACCEL"
bash "$HERE/build-ort.sh" ios-sim  arm64 Release "$HERE/build-ios-sim$TAG"    static "$ACCEL"

# Merge each slice's component archives, then create the xcframework.
bash "$ROOT/scripts/bundle-static.sh" "$HERE/build-ios-device$TAG/Release" dev/libonnxruntime.a
bash "$ROOT/scripts/bundle-static.sh" "$HERE/build-ios-sim$TAG/Release"    sim/libonnxruntime.a
rm -rf onnxruntime.xcframework
xcodebuild -create-xcframework \
  -library "$PWD/dev/libonnxruntime.a" -headers "$HDRS" \
  -library "$PWD/sim/libonnxruntime.a" -headers "$HDRS" \
  -output onnxruntime.xcframework

mkdir -p dist "staging/$ARCHIVE"
cp -R onnxruntime.xcframework "staging/$ARCHIVE/"
( cd "staging/$ARCHIVE" && cmake -E tar cf "$OLDPWD/dist/$ARCHIVE.zip" --format=zip onnxruntime.xcframework )
echo "packaged dist/$ARCHIVE.zip"
