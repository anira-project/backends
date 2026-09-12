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
#   [flavor]   variant selector for from-source -gpu legs: coreml | dml | webgpu or a
#              `+`-joined combination (coreml+webgpu, dml+webgpu) — see build-ort.sh
#              <accel>; for prebuilts it overrides the platform-derived repackage flavor
#              (linux-cuda / windows-cuda). CI passes it via the BACKENDS_FLAVOR env var
#              (CMake drops empty positional args, which would shift a trailing flavor into
#              the URL slot); the positional wins if given.
set -euo pipefail

PLATFORM="${1:?platform}"; ARCH="${2:?arch}"; CONFIG="${3:?config}"; KIND="${4:?kind}"
SOURCE="${5:?source}"; ST="${6:?staging dir}"; URL="${7:-}"; ABIS="${8:-}"
FLAVOR="${9:-${BACKENDS_FLAVOR:-}}"
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"   # backends/
mkdir -p "$ST/include" "$ST/lib"

# ---- repackage an upstream shared prebuilt (Linux/Windows release; the Android AAR flavor is
# kept for manual use — CI builds Android shared from source per ABI since 1.30, whose AAR
# reaches Maven days after the GitHub release) ---------------------------------------------
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
# GPU flavor -> build-ort.sh accel arg ("none" = CPU-only default). has_accel <x> tells
# whether the flavor carries that EP (flavors are `+`-joined, e.g. coreml+webgpu).
ACCEL="none"
case "$FLAVOR" in coreml|dml|webgpu|coreml+webgpu|dml+webgpu) ACCEL="$FLAVOR" ;; esac
has_accel() { case "+$ACCEL+" in *"+$1+"*) return 0 ;; *) return 1 ;; esac; }

# Pinned public headers — minus the per-EP provider headers, which ship ONLY in the variant
# that contains the EP (the smoke keys its extra forward pass on the header's presence, and
# CPU-only packages must not advertise an EP they don't contain): coreml_provider_factory.h
# for CoreML, webgpu_provider_factory.h (upstream's presence-marker header) for WebGPU.
for h in "$HERE"/include/*.h; do
  case "$(basename "$h")" in
    coreml_provider_factory.h) has_accel coreml || continue ;;
    webgpu_provider_factory.h) has_accel webgpu || continue ;;
  esac
  cp "$h" "$ST/include/"
done

# WebGPU variants ship the Dawn that build-ort.sh built from the ORT-pinned revision, INSIDE
# the ORT archive: lib/libwebgpu_dawn.{so,dylib} (webgpu_dawn.dll + .lib), include/webgpu +
# include/dawn (source + generated headers), and DAWN_VERSION (the pinned tag/hash) for the
# consumer's revision assertion. One archive = one ORT/Dawn/proc-table triple.
stage_dawn() {
  local src="$HERE/dawn-src" build="$HERE/dawn-build-$PLATFORM-$ARCH" inst="$HERE/dawn-install-$PLATFORM-$ARCH"
  [ -d "$inst" ] || { echo "ERROR: no Dawn install under $inst (build-ort.sh accel=webgpu should have produced it)"; exit 1; }
  local libs; libs="$(find "$inst" -type f \( -name 'libwebgpu_dawn.so*' -o -name 'libwebgpu_dawn.dylib' -o -name 'webgpu_dawn.dll' -o -name 'webgpu_dawn.lib' \) )"
  [ -n "$libs" ] || { echo "ERROR: no webgpu_dawn library under $inst"; exit 1; }
  echo "$libs" | while IFS= read -r f; do cp -P "$f" "$ST/lib/"; done
  # Dawn's public C/C++ headers: the source tree's include/ plus the generated ones
  # (webgpu.h / webgpu_cpp.h are generated from dawn.json), generated + installed winning.
  cp -R "$src/include/." "$ST/include/"
  [ -d "$build/gen/include" ] && cp -R "$build/gen/include/." "$ST/include/"
  [ -d "$inst/include" ] && cp -R "$inst/include/." "$ST/include/"
  [ -f "$ST/include/webgpu/webgpu.h" ] || { echo "ERROR: Dawn headers incomplete (no include/webgpu/webgpu.h)"; exit 1; }
  [ -f "$ST/include/dawn/native/DawnNative.h" ] || { echo "ERROR: Dawn headers incomplete (no include/dawn/native/DawnNative.h)"; exit 1; }
  [ -f "$src/.anira-dawn-rev" ] && cp "$src/.anira-dawn-rev" "$ST/DAWN_VERSION"
  # Windows: Dawn's D3D12 backend loads the DXC shader compiler (dxcompiler.dll + dxil.dll)
  # from beside webgpu_dawn.dll at device creation — ship the pinned redistributables.
  [ "$PLATFORM" = "windows" ] && bash "$ROOT/scripts/fetch-dxc.sh" "$ARCH" "$ST/lib"
  echo "staged Dawn $(cat "$ST/DAWN_VERSION" 2>/dev/null) into the package"
}

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

if [ "$KIND" = "shared" ] && has_accel dml; then
  # Windows DirectML gpu variant, built from source (no upstream DirectML package at
  # 1.25+). Ships onnxruntime.dll (DML EP compiled in) + import lib + the DirectML.dll
  # redist that dml.cmake nuget-restored into <build>/packages/, and the DML provider
  # header so consumers (and the smoke) can append the EP.
  bash "$HERE/build-ort.sh" "$PLATFORM" "$ARCH" "$CONFIG" "$HERE/build" shared "$ACCEL"
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
  has_accel webgpu && stage_dawn
  echo "staged onnxruntime ($PLATFORM/$ARCH/shared, $ACCEL) -> $ST"
  exit 0
fi

if [ "$KIND" = "shared" ]; then
  # From-source shared: macOS (every kind), Android (per ABI, bundled multi-ABI by CI) and the
  # Linux -gpu WebGPU variant (the CPU Linux/Windows shared come from prebuilt). Builds
  # libonnxruntime.{dylib,so} directly — one self-contained lib, no re2 force-build / no bundling.
  bash "$HERE/build-ort.sh" "$PLATFORM" "$ARCH" "$CONFIG" "$HERE/build" shared "$ACCEL"
  if [ "$PLATFORM" = "macos" ]; then
    dy="$(find "$HERE/build/$CONFIG" -maxdepth 1 -type f -name 'libonnxruntime*.dylib' | head -1)"
    [ -n "$dy" ] || { echo "ERROR: no shared dylib built under $HERE/build/$CONFIG"; exit 1; }
    cp "$dy" "$ST/lib/libonnxruntime.dylib"
    install_name_tool -id @rpath/libonnxruntime.dylib "$ST/lib/libonnxruntime.dylib"
  else
    # Keep the versioned .so AND its symlinks (SONAME libonnxruntime.so.1; consumers link
    # -lonnxruntime) — the same layout the repackaged upstream Linux prebuilt ships.
    so="$(find "$HERE/build/$CONFIG" -maxdepth 1 -name 'libonnxruntime.so*' | head -1)"
    [ -n "$so" ] || { echo "ERROR: no libonnxruntime.so built under $HERE/build/$CONFIG"; exit 1; }
    cp -P "$HERE/build/$CONFIG"/libonnxruntime.so* "$ST/lib/"
  fi
else
  # static (all platforms incl. Android) — build the component .a/.lib then merge them into
  # one self-contained archive. Exclude /testdata/ fixtures + the full libprotobuf/libprotoc
  # (build-time only; onnxruntime runs on protobuf-lite). The smoke link proves completeness.
  bash "$HERE/build-ort.sh" "$PLATFORM" "$ARCH" "$CONFIG" "$HERE/build" static "$ACCEL"
  if [ "$PLATFORM" = "windows" ]; then out="$ST/lib/onnxruntime.lib"; else out="$ST/lib/libonnxruntime.a"; fi
  # Also exclude Microsoft's 1DS client telemetry SDK if the tree built it (libmat + its
  # bundled sqlite/zlib under _deps/cpp_client_telemetry-build): anira packages report
  # nothing, and its objects drag Network.framework into every Apple consumer's link.
  BUNDLE_EXCLUDE_REGEX='/testdata/|libprotoc|libprotobuf[d]?\.(lib|a)|cpp_client_telemetry|telemetry_linux_http' \
    bash "$ROOT/scripts/bundle-static.sh" "$HERE/build/$CONFIG" "$out"
fi
has_accel webgpu && stage_dawn

echo "staged onnxruntime ($PLATFORM/$ARCH/$KIND) -> $ST"
