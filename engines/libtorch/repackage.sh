#!/usr/bin/env bash
# Repackage an UPSTREAM libtorch prebuilt (download.pytorch.org) into our archive
# layout. Unlike TFLite/ONNXRuntime (flat include/ + lib/), libtorch is consumed by
# anira via `find_package(Torch)`, so we must preserve the WHOLE package tree:
#   include/  lib/  share/cmake/Torch/   (+ bin/ on Windows, if present)
# Dropping share/ would break find_package (no TorchConfig.cmake) — so we keep it.
#
# PyTorch ships official CPU shared prebuilts for: macOS arm64, Linux x86_64,
# Windows x86_64. The gaps (macOS x86_64, Linux aarch64, Windows arm64 @ 2.12.0)
# are built from source — see build-libtorch.sh.
#
# Usage: repackage.sh <src> <staging-dir>
#   <src>          http(s) URL to the upstream .zip, or a local file path (testing)
#   <staging-dir>  output prefix; gets include/ lib/ share/ [bin/]
set -euo pipefail

SRC="${1:?src url/path}"; ST="${2:?staging dir}"
mkdir -p "$ST"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

# Fetch (or use a local file as-is for testing).
dl="$tmp/libtorch.zip"
case "$SRC" in
  http://*|https://*) curl -fSL --retry 3 -o "$dl" "$SRC" ;;
  *) dl="$SRC" ;;
esac

# Every upstream libtorch archive (zip) extracts to a single top-level `libtorch/`.
# `cmake -E tar` (libarchive) handles .zip on every runner incl. git-bash (no `unzip`).
( cd "$tmp" && cmake -E tar xf "$dl" )
root="$(find "$tmp" -maxdepth 1 -type d -name 'libtorch' | head -1)"
[ -n "$root" ] || { echo "ERROR: no top-level libtorch/ dir in $SRC"; exit 1; }

# Copy the package tree verbatim. include/, lib/, share/ are always present;
# bin/ exists on some Windows builds (extra DLLs) — keep it if so.
for d in include lib share bin; do
  [ -d "$root/$d" ] && cp -R "$root/$d" "$ST/"
done

[ -d "$ST/include" ] || { echo "ERROR: repackaged tree missing include/"; exit 1; }
[ -d "$ST/lib" ]     || { echo "ERROR: repackaged tree missing lib/"; exit 1; }
[ -f "$ST/share/cmake/Torch/TorchConfig.cmake" ] || \
  { echo "ERROR: share/cmake/Torch/TorchConfig.cmake missing — find_package(Torch) would fail"; exit 1; }

echo "repackaged -> $ST"
du -sh "$ST" 2>/dev/null | sed 's/^/  /' || true
( cd "$ST" && find . -maxdepth 2 -type d | sort | sed 's/^/  /' )
