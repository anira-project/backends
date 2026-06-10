#!/usr/bin/env bash
# Build (or repackage) onnxruntime for ONE target and stage include/ + lib/ into <staging>.
# Consolidates what onnxruntime.yml previously did inline: build-ort.sh + bundle-static.sh +
# header copy for static; build-ort.sh + dylib restage for macOS shared; repackage-shared.sh
# for the upstream shared prebuilts. Called by the root CMake orchestrator (cmake/ExternalEngine.cmake)
# and reused by CI, so the build commands live in one place.
#
# Usage: stage.sh <platform> <arch> <config> <kind> <source> <staging> [url] [abis]
#   <platform> macos|linux|windows|android   <arch> x86_64|arm64|aarch64|arm64-v8a|multi
#   <config>   Release|Debug                 <kind> static|shared
#   <source>   build|prebuilt                <staging> output prefix (include/ + lib/)
#   [url]      prebuilt download URL (source=prebuilt)
#   [abis]     android-aar only: space-separated ABIs (e.g. "arm64-v8a x86_64")
set -euo pipefail

PLATFORM="${1:?platform}"; ARCH="${2:?arch}"; CONFIG="${3:?config}"; KIND="${4:?kind}"
SOURCE="${5:?source}"; ST="${6:?staging dir}"; URL="${7:-}"; ABIS="${8:-}"
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"   # backends/
mkdir -p "$ST/include" "$ST/lib"

# ---- repackage an upstream shared prebuilt (Linux/Windows release, Android AAR) -----------
if [ "$SOURCE" = "prebuilt" ]; then
  : "${URL:?prebuilt source needs a URL}"
  case "$PLATFORM" in
    linux)   flavor=linux ;;
    windows) flavor=windows ;;
    android) flavor=android-aar ;;
    *) echo "ERROR: no onnxruntime shared prebuilt for platform '$PLATFORM'"; exit 1 ;;
  esac
  bash "$HERE/repackage-shared.sh" "$flavor" "$URL" "$ST" "$ABIS"
  exit 0
fi

# ---- build from source --------------------------------------------------------------------
cp "$HERE"/include/*.h "$ST/include/"

if [ "$KIND" = "shared" ]; then
  # macOS only (Linux/Windows/Android shared come from prebuilt). Builds libonnxruntime.dylib
  # directly — one self-contained lib, no re2 force-build / no bundling.
  bash "$HERE/build-ort.sh" "$PLATFORM" "$ARCH" "$CONFIG" build shared
  dy="$(find "$HERE/build/$CONFIG" -maxdepth 1 -type f -name 'libonnxruntime*.dylib' | head -1)"
  [ -n "$dy" ] || { echo "ERROR: no shared dylib built under $HERE/build/$CONFIG"; exit 1; }
  cp "$dy" "$ST/lib/libonnxruntime.dylib"
  install_name_tool -id @rpath/libonnxruntime.dylib "$ST/lib/libonnxruntime.dylib"
else
  # static (all platforms incl. Android) — build the component .a/.lib then merge them into
  # one self-contained archive. Exclude /testdata/ fixtures + the full libprotobuf/libprotoc
  # (build-time only; onnxruntime runs on protobuf-lite). The smoke link proves completeness.
  bash "$HERE/build-ort.sh" "$PLATFORM" "$ARCH" "$CONFIG" build static
  if [ "$PLATFORM" = "windows" ]; then out="$ST/lib/onnxruntime.lib"; else out="$ST/lib/libonnxruntime.a"; fi
  BUNDLE_EXCLUDE_REGEX='/testdata/|libprotoc|libprotobuf[d]?\.(lib|a)' \
    bash "$ROOT/shared/bundle-static.sh" "$HERE/build/$CONFIG" "$out"
fi

echo "staged onnxruntime ($PLATFORM/$ARCH/$KIND) -> $ST"
