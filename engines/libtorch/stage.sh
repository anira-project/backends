#!/usr/bin/env bash
# Stage CPU SHARED libtorch for ONE target into <staging> as the full package tree
# (include/ lib/ share/cmake/Torch/ [bin/]), consumed by anira via find_package(Torch).
# Either repackage an upstream download.pytorch.org prebuilt, or build from source where
# PyTorch ships no prebuilt at this version. Called by the root CMake orchestrator
# (cmake/ExternalEngine.cmake) and reused by CI.
#
# Usage: stage.sh <platform> <arch> <config> <kind> <source> <staging> [url] [flavor]
#   <platform> macos|linux|windows   <arch> x86_64|aarch64|arm64
#   <config>   Release (libtorch ships Release only)   <kind> shared
#   <source>   build|prebuilt        <staging> output prefix
#   [url]      prebuilt download URL (source=prebuilt)
#   [flavor]   GPU variant (docs/gpu-support.md): "mps" (macOS arm64 -gpu, from source)
#              or "cuda" (Linux/Windows x64 -cuda, repackaged upstream CUDA prebuilt
#              with the NVIDIA redist libs stripped — user provides CUDA + cuDNN)
set -euo pipefail

PLATFORM="${1:?platform}"; ARCH="${2:?arch}"; CONFIG="${3:?config}"; KIND="${4:?kind}"
SOURCE="${5:?source}"; ST="${6:?staging dir}"; URL="${7:-}"
# CI passes the flavor via env (CMake drops empty positional args); positional wins.
FLAVOR="${8:-${BACKENDS_FLAVOR:-}}"
HERE="$(cd "$(dirname "$0")" && pwd)"

if [ "$SOURCE" = "prebuilt" ]; then
  : "${URL:?prebuilt source needs a URL}"
  bash "$HERE/repackage.sh" "$URL" "$ST" "${FLAVOR:+$FLAVOR}"
else
  bash "$HERE/build-libtorch.sh" "$PLATFORM" "$ARCH" "$ST" "${FLAVOR:-none}"
fi

echo "staged libtorch ($PLATFORM/$ARCH/$KIND/$SOURCE${FLAVOR:+/$FLAVOR}) -> $ST"
