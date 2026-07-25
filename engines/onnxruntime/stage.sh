#!/usr/bin/env bash
# Build (or repackage) onnxruntime for ONE target and stage include/ + lib/ into <staging>.
# Consolidates what onnxruntime.yml previously did inline: build-ort.sh + bundle-static.sh +
# header copy for static; build-ort.sh + dylib restage for macOS shared; repackage-shared.sh
# for the upstream shared prebuilts. Called by the root CMake orchestrator (cmake/ExternalEngine.cmake)
# and reused by CI, so the build commands live in one place.
#
# Usage: stage.sh <platform> <arch> <config> <kind> <source> <staging> [url] [abis] [flavor]
#   <platform> macos|linux|windows|android   <arch> x86_64|arm64|aarch64|arm64-v8a|multi
#   <config>   Release|Debug                 <kind> static|shared
#   <source>   build|prebuilt                <staging> output prefix (include/ + lib/)
#   [url]      prebuilt download URL (source=prebuilt)
#   [abis]     android-aar only: space-separated ABIs (e.g. "arm64-v8a x86_64")
#   [flavor]   variant selector (docs/gpu-support.md): "dml" builds the Windows DirectML
#              gpu variant from source; for prebuilts it overrides the platform-derived
#              repackage flavor (e.g. linux-cuda / windows-cuda).
set -euo pipefail

PLATFORM="${1:?platform}"; ARCH="${2:?arch}"; CONFIG="${3:?config}"; KIND="${4:?kind}"
SOURCE="${5:?source}"; ST="${6:?staging dir}"; URL="${7:-}"; ABIS="${8:-}"; FLAVOR="${9:-}"
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"   # backends/
mkdir -p "$ST/include" "$ST/lib"

# ---- repackage an upstream shared prebuilt (Linux/Windows release, Android AAR) -----------
if [ "$SOURCE" = "prebuilt" ]; then
  : "${URL:?prebuilt source needs a URL}"
  if [ -n "$FLAVOR" ]; then
    flavor="$FLAVOR"   # variant legs (linux-cuda / windows-cuda) name their flavor in the preset
  else
    case "$PLATFORM" in
      linux)   flavor=linux ;;
      windows) flavor=windows ;;
      android) flavor=android-aar ;;
      *) echo "ERROR: no onnxruntime shared prebuilt for platform '$PLATFORM'"; exit 1 ;;
    esac
  fi
  bash "$HERE/repackage-shared.sh" "$flavor" "$URL" "$ST" "$ABIS"
  exit 0
fi

# ---- build from source --------------------------------------------------------------------
# Pinned public headers — minus the CoreML provider header, which ships ONLY in the
# macOS gpu variant (the smoke keys its CoreML pass on that header's presence, and
# CPU-only packages must not advertise an EP they don't contain).
for h in "$HERE"/include/*.h; do
  [ "$(basename "$h")" = "coreml_provider_factory.h" ] && [ "$FLAVOR" != "coreml" ] && continue
  cp "$h" "$ST/include/"
done

# GPU flavor -> build-ort.sh accel arg ("" = CPU-only default).
ACCEL="none"
case "$FLAVOR" in coreml|dml) ACCEL="$FLAVOR" ;; esac

if [ "$PLATFORM" = "wasm" ]; then
  # Emscripten static lib: build-ort.sh emits ONE self-contained libonnxruntime_webassembly.a
  # (deps bundled by --build_wasm_static_lib) — no re2 force-build / bundle-static.sh. Ship it
  # as libonnxruntime.a so consumers link the same name as every other static target.
  bash "$HERE/build-ort.sh" wasm wasm32 "$CONFIG" "$HERE/build" static
  a="$(find "$HERE/build/$CONFIG" -maxdepth 2 -name 'libonnxruntime_webassembly.a' | head -1)"
  [ -n "$a" ] || { echo "ERROR: no wasm static lib under $HERE/build/$CONFIG"; exit 1; }
  cp "$a" "$ST/lib/libonnxruntime.a"
  echo "staged onnxruntime (wasm/wasm32/static) -> $ST"
  exit 0
fi

if [ "$KIND" = "shared" ] && [ "$FLAVOR" = "dml" ]; then
  # Windows DirectML gpu variant, built from source (no upstream DirectML package at
  # 1.25+). Ships onnxruntime.dll (DML EP compiled in) + import lib + the DirectML.dll
  # redist that dml.cmake nuget-restored into <build>/packages/, and the DML provider
  # header so consumers (and the smoke) can append the EP.
  bash "$HERE/build-ort.sh" "$PLATFORM" "$ARCH" "$CONFIG" "$HERE/build" shared dml
  for f in onnxruntime.dll onnxruntime.lib; do
    src="$(find "$HERE/build/$CONFIG" -maxdepth 1 -type f -name "$f" | head -1)"
    [ -n "$src" ] || { echo "ERROR: no $f built under $HERE/build/$CONFIG"; exit 1; }
    cp "$src" "$ST/lib/"
  done
  case "$ARCH" in x86_64) dmlarch=x64 ;; *) dmlarch="$ARCH" ;; esac
  dml="$(find "$HERE/build" -type f -path "*Microsoft.AI.DirectML*/bin/${dmlarch}-win/DirectML.dll" | head -1)"
  [ -n "$dml" ] || { echo "ERROR: DirectML.dll (${dmlarch}-win) not found under $HERE/build — nuget restore failed?"; exit 1; }
  cp "$dml" "$ST/lib/"
  cp "$HERE/onnxruntime-src/include/onnxruntime/core/providers/dml/dml_provider_factory.h" "$ST/include/"
  echo "staged onnxruntime ($PLATFORM/$ARCH/shared, DirectML) -> $ST"
  exit 0
fi

if [ "$KIND" = "shared" ]; then
  # macOS only (Linux/Windows/Android shared come from prebuilt). Builds libonnxruntime.dylib
  # directly — one self-contained lib, no re2 force-build / no bundling.
  bash "$HERE/build-ort.sh" "$PLATFORM" "$ARCH" "$CONFIG" "$HERE/build" shared "$ACCEL"
  dy="$(find "$HERE/build/$CONFIG" -maxdepth 1 -type f -name 'libonnxruntime*.dylib' | head -1)"
  [ -n "$dy" ] || { echo "ERROR: no shared dylib built under $HERE/build/$CONFIG"; exit 1; }
  cp "$dy" "$ST/lib/libonnxruntime.dylib"
  install_name_tool -id @rpath/libonnxruntime.dylib "$ST/lib/libonnxruntime.dylib"
else
  # static (all platforms incl. Android) — build the component .a/.lib then merge them into
  # one self-contained archive. Exclude /testdata/ fixtures + the full libprotobuf/libprotoc
  # (build-time only; onnxruntime runs on protobuf-lite). The smoke link proves completeness.
  bash "$HERE/build-ort.sh" "$PLATFORM" "$ARCH" "$CONFIG" "$HERE/build" static "$ACCEL"
  if [ "$PLATFORM" = "windows" ]; then out="$ST/lib/onnxruntime.lib"; else out="$ST/lib/libonnxruntime.a"; fi
  BUNDLE_EXCLUDE_REGEX='/testdata/|libprotoc|libprotobuf[d]?\.(lib|a)' \
    bash "$ROOT/scripts/bundle-static.sh" "$HERE/build/$CONFIG" "$out"
fi

echo "staged onnxruntime ($PLATFORM/$ARCH/$KIND) -> $ST"
