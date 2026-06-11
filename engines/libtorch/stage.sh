#!/usr/bin/env bash
# Stage CPU SHARED libtorch for ONE target into <staging> as the full package tree
# (include/ lib/ share/cmake/Torch/ [bin/]), consumed by anira via find_package(Torch).
# Either repackage an upstream download.pytorch.org prebuilt, or build from source where
# PyTorch ships no prebuilt at this version. Called by the root CMake orchestrator
# (cmake/ExternalEngine.cmake) and reused by CI.
#
# Usage: stage.sh <platform> <arch> <config> <kind> <source> <staging> [url]
#   <platform> macos|linux|windows   <arch> x86_64|aarch64|arm64
#   <config>   Release (libtorch ships Release only)   <kind> shared
#   <source>   build|prebuilt        <staging> output prefix
#   [url]      prebuilt download URL (source=prebuilt)
set -euo pipefail

PLATFORM="${1:?platform}"; ARCH="${2:?arch}"; CONFIG="${3:?config}"; KIND="${4:?kind}"
SOURCE="${5:?source}"; ST="${6:?staging dir}"; URL="${7:-}"
HERE="$(cd "$(dirname "$0")" && pwd)"

if [ "$SOURCE" = "prebuilt" ]; then
  : "${URL:?prebuilt source needs a URL}"
  bash "$HERE/repackage.sh" "$URL" "$ST"
else
  bash "$HERE/build-libtorch.sh" "$PLATFORM" "$ARCH" "$ST"
fi

echo "staged libtorch ($PLATFORM/$ARCH/$KIND/$SOURCE) -> $ST"
