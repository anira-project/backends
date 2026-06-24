#!/usr/bin/env bash
# iOS (executorch) STATIC xcframework. Built via ExecuTorch's OWN apple CMake presets
# (`ios` + `ios-simulator`) — the same path scripts/build_apple_frameworks.sh uses — because
# they build the host flatc/flatcc tools correctly during the cross-compile (a hand-rolled
# ios-cmake toolchain leaks the iOS SDK/deployment target into the host-tool builds and breaks
# them). The presets already enable the full CPU set we want: optimized + quantized kernels,
# XNNPACK, and the CoreML/MPS delegates. We then merge each slice's static archives and combine
# device (OS64) + simulator (arm64) into a STATIC .xcframework. No buck2 (that's only ExecuTorch's
# header-export path); headers come from `cmake --install`. Produces dist/<archive>.zip.
#
# NOTE: first-cut Apple cross-compile — expect CI iteration (SDK/codesign/xcframework metadata).
#
# Usage: ios.sh <archive-name>
set -euo pipefail
ARCHIVE="${1:?archive name}"
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
SRC="$HERE/src/executorch"
VER="$(tr -d '[:space:]' < "$HERE/VERSION")"

# Source (setup-toolchain usually restores this from cache; clone if absent). Leaf must be
# named exactly `executorch` (upstream issue 6475), nested under src/ to keep the engine's
# VERSION file off the include path (case-insensitive <version> clash).
if [ ! -d "$SRC/.git" ]; then
  mkdir -p "$HERE/src"
  git clone --depth 1 --recurse-submodules --shallow-submodules \
    --branch "v${VER}" https://github.com/pytorch/executorch "$SRC"
fi

# Host torch wheel (macOS arm64) supplies the ATen headers the optimized kernels need at
# configure (cross-compile uses the host's headers — they're arch-independent). Strip lintrunner.
python -m pip install --upgrade pip
if [ -f "$SRC/requirements-dev.txt" ]; then
  grep -viE 'lintrunner' "$SRC/requirements-dev.txt" > "$SRC/.et-build-reqs.txt"
  python -m pip install -r "$SRC/.et-build-reqs.txt"
fi
python -m pip install pyyaml setuptools wheel "torch==2.12.0" \
  --extra-index-url https://download.pytorch.org/whl/test/cpu
export PYTHONPATH="$SRC${PYTHONPATH:+:$PYTHONPATH}"

# Cap parallelism by RAM (same OOM guard as the desktop build).
ncores=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)
memgb=$(( $(sysctl -n hw.memsize 2>/dev/null || echo 8589934592) / 1073741824 ))
JOBS=$(( memgb / 3 )); [ "$JOBS" -lt 2 ] && JOBS=2; [ "$JOBS" -gt "$ncores" ] && JOBS=$ncores

build_slice() {  # <preset> <build-dir>
  local preset="$1" out="$2"
  rm -rf "$out"
  echo "== iOS build: preset=$preset -j$JOBS =="
  # The apple presets use the Xcode (multi-config) generator -> every build/install needs an
  # explicit --config. Trim the preset's LLM/torchao extras (irrelevant to a CPU audio backend)
  # to match the desktop/Android op set + speed up the build; keep XNNPACK + optimized/quantized
  # kernels and the CoreML + MPS GPU/ANE delegates (the iOS hardware-accel paths).
  cmake -S "$SRC" -B "$out" --preset "$preset" \
    -DPYTHON_EXECUTABLE="$(command -v python)" \
    -DEXECUTORCH_BUILD_EXTENSION_LLM=OFF \
    -DEXECUTORCH_BUILD_EXTENSION_LLM_RUNNER=OFF \
    -DEXECUTORCH_BUILD_EXTENSION_LLM_APPLE=OFF \
    -DEXECUTORCH_BUILD_KERNELS_LLM=OFF \
    -DEXECUTORCH_BUILD_KERNELS_TORCHAO=OFF
  cmake --build "$out" --config Release -j "$JOBS"
}

build_slice ios           "$SRC/cmake-out-ios"
build_slice ios-simulator "$SRC/cmake-out-ios-sim"

# Merge each slice's transitive static archives (executorch + kernels + xnnpack/coreml/_deps
# CMake scatters across the build tree) into one self-contained fat libexecutorch.a per slice.
# EXCLUDE the flatc/flatcc host-tool ExternalProjects: those build for the macOS HOST (to run
# the schema compiler during the build), so their libs are macOS-platform Mach-O. Sweeping them
# into the iOS bundle makes the archive "multiple platforms" and xcframework rejects it. The
# host tools aren't part of the shipped runtime, so dropping them is correct.
export BUNDLE_EXCLUDE_REGEX='/flatc_ep/|/flatcc_ep/'
rm -rf dev sim && mkdir -p dev sim
bash "$ROOT/scripts/bundle-static.sh" "$SRC/cmake-out-ios"     "$PWD/dev/libexecutorch.a"
bash "$ROOT/scripts/bundle-static.sh" "$SRC/cmake-out-ios-sim" "$PWD/sim/libexecutorch.a"

# Public headers from an install of the device slice (xcframework just needs include/ + the lib;
# no find_package, so the build-tree-path install quirk is irrelevant here). --config Release is
# required for the Xcode multi-config generator. Show output so a failure is diagnosable.
rm -rf "$HERE/ios-inst"
cmake --install "$SRC/cmake-out-ios" --config Release --prefix "$HERE/ios-inst" || true
hdrs="$HERE/ios-inst/include"
[ -d "$hdrs" ] || { echo "ERROR: no installed include/ for the iOS xcframework under $HERE/ios-inst"; ls -la "$HERE/ios-inst" 2>/dev/null || true; exit 1; }

rm -rf executorch.xcframework
xcodebuild -create-xcframework \
  -library "$PWD/dev/libexecutorch.a" -headers "$hdrs" \
  -library "$PWD/sim/libexecutorch.a" -headers "$hdrs" \
  -output executorch.xcframework

mkdir -p dist "staging/$ARCHIVE"
cp -R executorch.xcframework "staging/$ARCHIVE/"
( cd "staging/$ARCHIVE" && cmake -E tar cf "$OLDPWD/dist/$ARCHIVE.zip" --format=zip executorch.xcframework )
echo "packaged dist/$ARCHIVE.zip"
