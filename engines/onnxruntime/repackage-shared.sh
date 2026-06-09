#!/usr/bin/env bash
# Repackage an UPSTREAM onnxruntime prebuilt SHARED binary into our archive layout
# (include/ + lib/). Microsoft ships official shared libs for Linux/Windows (GitHub
# release) and Android (Maven AAR), so we restage those instead of building from
# source. macOS x86_64 is NOT shipped upstream — that one is built from source.
#
# Usage: repackage-onnx-shared.sh <flavor> <src> <staging-dir> [abi-list]
#   <flavor>  linux | windows | android-aar
#   <src>     http(s) URL, or a local file path (for testing)
#   <abi-list> android only: space-separated ABIs to keep (e.g. "arm64-v8a x86_64")
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
  linux)
    tar xzf "$dl" -C "$tmp"
    d="$(find "$tmp" -maxdepth 1 -type d -name 'onnxruntime-linux-*' | head -1)"
    cp -R "$d/include/." "$ST/include/"
    # Keep the versioned .so AND its unversioned symlink (consumers link -lonnxruntime).
    cp -P "$d"/lib/libonnxruntime.so* "$ST/lib/"
    ;;
  windows)
    unzip -q "$dl" -d "$tmp"
    d="$(find "$tmp" -maxdepth 1 -type d -name 'onnxruntime-win-*' | head -1)"
    cp -R "$d/include/." "$ST/include/"
    # DLL + import lib only — drop the ~400 MB .pdb and the provider-bridge shim.
    cp "$d/lib/onnxruntime.dll" "$d/lib/onnxruntime.lib" "$ST/lib/"
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