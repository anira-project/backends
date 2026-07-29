#!/usr/bin/env bash
# Repackage an UPSTREAM onnxruntime prebuilt SHARED binary into our archive layout
# (include/ + lib/). Microsoft ships official shared libs for Linux/Windows (GitHub
# release) and Android (Maven AAR), so we restage those instead of building from
# source. macOS x86_64 is NOT shipped upstream — that one is built from source.
#
# Usage: repackage-onnx-shared.sh <flavor> <src> <staging-dir> [abi-list]
#   <flavor>  linux | windows | android-aar | linux-cuda | windows-cuda
#   <src>     http(s) URL, or a local file path (for testing)
#   <abi-list> android only: space-separated ABIs to keep (e.g. "arm64-v8a x86_64")
#
# *-cuda: repackage the upstream `-gpu` prebuilt (CUDA EP) — keeps the CUDA provider +
# the provider-bridge shim (loaded on demand; the base lib runs CPU-only without them),
# drops the TensorRT provider (needs a TensorRT install; the CUDA EP covers the NVIDIA
# need). CUDA runtime + cuDNN are user-provided at runtime.
set -euo pipefail

FLAVOR="${1:?flavor}"; SRC="${2:?src url/path}"; ST="${3:?staging dir}"; ABIS="${4:-}"
mkdir -p "$ST/include" "$ST/lib"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

# Fetch (or use a local file as-is for testing).
dl="$tmp/dl"
case "$SRC" in
  http://*|https://*) curl -fsSL -o "$dl" "$SRC" ;;
  *) dl="$SRC" ;;
esac

case "$FLAVOR" in
  linux|linux-cuda)
    tar xzf "$dl" -C "$tmp"
    d="$(find "$tmp" -maxdepth 1 -type d -name 'onnxruntime-linux-*' | head -1)"
    cp -R "$d/include/." "$ST/include/"
    # Keep the versioned .so AND its unversioned symlink (consumers link -lonnxruntime).
    cp -P "$d"/lib/libonnxruntime.so* "$ST/lib/"
    if [ "$FLAVOR" = "linux-cuda" ]; then
      # CUDA EP: the bridge shim + provider are dlopen'd when the consumer appends the
      # EP; without them (or without CUDA/cuDNN installed) the lib still runs CPU-only.
      cp -P "$d"/lib/libonnxruntime_providers_shared.so "$ST/lib/"
      cp -P "$d"/lib/libonnxruntime_providers_cuda.so "$ST/lib/"
    fi
    ;;
  windows|windows-cuda)
    # cmake's tar (libarchive) handles .zip and is on every runner — git-bash on the
    # Windows runner has no `unzip`.
    ( cd "$tmp" && cmake -E tar xf "$dl" )
    d="$(find "$tmp" -maxdepth 1 -type d -name 'onnxruntime-win-*' | head -1)"
    cp -R "$d/include/." "$ST/include/"
    # DLL + import lib only — drop the ~400 MB .pdb (and for the cpu flavor the
    # provider-bridge shim; the cuda flavor needs it).
    cp "$d/lib/onnxruntime.dll" "$d/lib/onnxruntime.lib" "$ST/lib/"
    if [ "$FLAVOR" = "windows-cuda" ]; then
      cp "$d"/lib/onnxruntime_providers_shared.dll "$d"/lib/onnxruntime_providers_shared.lib "$ST/lib/" 2>/dev/null || \
        cp "$d"/lib/onnxruntime_providers_shared.dll "$ST/lib/"
      cp "$d"/lib/onnxruntime_providers_cuda.dll "$ST/lib/"
      # The gpu prebuilt may ship the DML provider header; drop it — this package has no
      # DML EP, and the smoke enables its DML pass on that header's presence.
      rm -f "$ST/include/dml_provider_factory.h"
    fi
    ;;
  android-aar)
    unzip -q "$dl" -d "$tmp"
    cp -R "$tmp/headers/." "$ST/include/"
    : "${ABIS:?android-aar needs an ABI list}"
    for abi in $ABIS; do
      [ -f "$tmp/jni/$abi/libonnxruntime.so" ] || { echo "ERROR: no libonnxruntime.so for ABI $abi"; exit 1; }
      mkdir -p "$ST/lib/$abi"
      cp "$tmp/jni/$abi/libonnxruntime.so" "$ST/lib/$abi/"   # not libonnxruntime4j_jni.so (Java binding)
    done
    ;;
  *) echo "ERROR: unknown flavor '$FLAVOR'"; exit 1 ;;
esac

echo "repackaged $FLAVOR -> $ST"
( cd "$ST" && find . -type f -o -type l | sort | sed 's/^/  /' )