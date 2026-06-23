#!/usr/bin/env bash
# iOS (executorch) STATIC: build the runtime from source for device (OS64) + simulator
# (SIMULATORARM64), arm64 only, then merge each slice's transitive static archives into one
# libexecutorch.a and combine into a STATIC .xcframework — full optimized CPU op set +
# XNNPACK + CoreML (no MLX; that's Apple-Silicon-Mac only). Mirrors the desktop static build;
# same per-slice transitive-archive merge as the onnx/litert iOS legs. Produces dist/<archive>.zip.
#
# NOTE: the Apple cross-compile flags (build-executorch.sh ios/ios-sim cases) are best-effort
# and may need CI iteration on a macOS runner — the ios-cmake toolchain, CoreML framework
# linkage, and static-xcframework metadata are the fiddly bits (cf. onnx/litert ios.sh).
#
# Usage: ios.sh <archive-name>   (produces dist/<archive>.zip)
set -euo pipefail
ARCHIVE="${1:?archive name}"
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
SRC="$HERE/src/executorch"

# Device + simulator static builds (each leaves its own cmake-out-<platform>-arm64 build tree).
bash "$HERE/build-executorch.sh" ios     arm64 "$HERE/stage-ios-device"
bash "$HERE/build-executorch.sh" ios-sim arm64 "$HERE/stage-ios-sim"

# Merge each slice's transitive archives (executorch + kernels + xnnpack/coreml/_deps that
# CMake scatters across the build tree) into one self-contained fat libexecutorch.a per slice.
rm -rf dev sim && mkdir -p dev sim
bash "$ROOT/scripts/bundle-static.sh" "$SRC/cmake-out-ios-arm64"     "$PWD/dev/libexecutorch.a"
bash "$ROOT/scripts/bundle-static.sh" "$SRC/cmake-out-ios-sim-arm64" "$PWD/sim/libexecutorch.a"

# Combine the device + simulator arm64 slices into a static .xcframework.
rm -rf executorch.xcframework
xcodebuild -create-xcframework \
  -library "$PWD/dev/libexecutorch.a" -headers "$HERE/stage-ios-device/include" \
  -library "$PWD/sim/libexecutorch.a" -headers "$HERE/stage-ios-sim/include" \
  -output executorch.xcframework

mkdir -p dist "staging/$ARCHIVE"
cp -R executorch.xcframework "staging/$ARCHIVE/"
( cd "staging/$ARCHIVE" && cmake -E tar cf "$OLDPWD/dist/$ARCHIVE.zip" --format=zip executorch.xcframework )
echo "packaged dist/$ARCHIVE.zip"
