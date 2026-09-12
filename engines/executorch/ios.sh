#!/usr/bin/env bash
# iOS (executorch) STATIC xcframework. Built via ExecuTorch's OWN apple CMake presets
# (`ios` + `ios-simulator`) — the same path scripts/build_apple_frameworks.sh uses — because
# they build the host flatc/flatcc tools correctly during the cross-compile (a hand-rolled
# ios-cmake toolchain leaks the iOS SDK/deployment target into the host-tool builds and breaks
# them). The presets already enable the full CPU set we want: optimized + quantized kernels and
# XNNPACK; their CoreML/MPS delegates are switched off in the CPU default and kept in the
# -gpu variant (GPU is always a separate archive). Each slice is installed and merged into
# ONE libexecutorch.a with the kernel/backend registrations pre-linked (merge-static.sh — a
# plain archive merge would drop them; the -gpu variant adds the delegates' registrations to
# that blob), then device (OS64) + simulator (arm64) combine into a STATIC .xcframework. No
# buck2 (that's only ExecuTorch's header-export path); headers come from `cmake --install`.
# Produces dist/<archive>.zip.
#
# NOTE: first-cut Apple cross-compile — expect CI iteration (SDK/codesign/xcframework metadata).
#
# Usage: ios.sh <archive-name> [variant]
#   [variant]  "" (CPU default: XNNPACK + kernels, delegates OFF) | gpu (CoreML + MPS
#              delegates — the upstream apple presets' default). Consumers of the -gpu
#              xcframework link CoreML, Accelerate, Metal, MetalPerformanceShaders,
#              MetalPerformanceShadersGraph, Foundation and libsqlite3.
set -euo pipefail
ARCHIVE="${1:?archive name}"; VARIANT="${2:-}"
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

# Variant flags: the upstream apple presets default the CoreML + MPS delegates ON — that's
# exactly the -gpu variant, whose registrations join the merge blob below. The CPU default
# archive turns them OFF (GPU is always a separate archive; matches the desktop packages).
VFLAGS=(); TAG=""; DELEGATES=""
if [ "$VARIANT" = "gpu" ]; then
  TAG="-gpu"; DELEGATES="coremldelegate mpsdelegate"
else
  VFLAGS+=(-DEXECUTORCH_BUILD_COREML=OFF -DEXECUTORCH_BUILD_MPS=OFF)
fi

build_slice() {  # <preset> <build-dir>
  local preset="$1" out="$2"
  rm -rf "$out"
  echo "== iOS build: preset=$preset variant=${VARIANT:-cpu} -j$JOBS =="
  # The apple presets use the Xcode (multi-config) generator -> every build/install needs an
  # explicit --config. Trim the preset's LLM/torchao extras (irrelevant to a CPU audio backend)
  # to match the desktop/Android op set + speed up the build; keep XNNPACK + optimized/quantized
  # kernels; the CoreML + MPS delegates only in the -gpu variant.
  cmake -S "$SRC" -B "$out" --preset "$preset" \
    -DPYTHON_EXECUTABLE="$(command -v python)" \
    -DEXECUTORCH_BUILD_EXTENSION_LLM=OFF \
    -DEXECUTORCH_BUILD_EXTENSION_LLM_RUNNER=OFF \
    -DEXECUTORCH_BUILD_EXTENSION_LLM_APPLE=OFF \
    -DEXECUTORCH_BUILD_KERNELS_LLM=OFF \
    -DEXECUTORCH_BUILD_KERNELS_TORCHAO=OFF \
    ${VFLAGS[@]+"${VFLAGS[@]}"}   # bash 3.2: an empty array is "unbound" under set -u
  cmake --build "$out" --config Release -j "$JOBS"
}

# Per-variant build dirs: the cpu and gpu xcframeworks are separate CI jobs off one cached
# source tree, and a reconfigure across variants must not inherit the other's cache.
build_slice ios           "$SRC/cmake-out-ios$TAG"
build_slice ios-simulator "$SRC/cmake-out-ios-sim$TAG"

# Install each slice (the CMake package it writes is what merge-static.sh reads the member
# list and the force-load set off; the flatc/flatcc HOST tools are not exported targets, so
# they never enter the merge — sweeping them in made the archive "multiple platforms" before),
# then merge into one libexecutorch.a per slice with the registrations pre-linked.
# --config Release is required for the Xcode multi-config generator.
# ExecuTorch installs XNNPACK's OBJECT libraries as targets. Under the Xcode generator for
# iOS the objects live in build/<t>.build/Release-iphoneos|iphonesimulator/Objects-normal/,
# but CMake's object-install rule looks under plain Release/ (it ignores the effective
# platform suffix for objects, unlike for libraries) and the install aborts before the
# export files are written. Alias Release -> Release-<platform> so the rule finds them.
alias_xcode_config() {  # <build-dir>
  local d eff
  for d in "$1"/build/*.build; do
    [ -d "$d" ] || continue
    for eff in "$d"/Release-*; do
      [ -d "$eff" ] && [ ! -e "$d/Release" ] && ln -s "$(basename "$eff")" "$d/Release"
    done
  done
}
rm -rf "$HERE/ios-inst" "$HERE/ios-sim-inst" dev sim && mkdir -p dev sim
alias_xcode_config "$SRC/cmake-out-ios$TAG"
alias_xcode_config "$SRC/cmake-out-ios-sim$TAG"
cmake --install "$SRC/cmake-out-ios$TAG"     --config Release --prefix "$HERE/ios-inst"
cmake --install "$SRC/cmake-out-ios-sim$TAG" --config Release --prefix "$HERE/ios-sim-inst"
MERGE_DELEGATES="$DELEGATES" bash "$HERE/merge-static.sh" ios "$HERE/ios-inst"     "$PWD/dev/libexecutorch.a"
MERGE_DELEGATES="$DELEGATES" bash "$HERE/merge-static.sh" ios "$HERE/ios-sim-inst" "$PWD/sim/libexecutorch.a"

# Public headers from the device slice's install (the xcframework just needs include/ + the lib).
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
