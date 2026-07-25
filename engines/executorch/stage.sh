#!/usr/bin/env bash
# Stage a STATIC, CPU-first ExecuTorch runtime for ONE desktop target into <staging> as the
# find_package(executorch)-consumable package tree (include/ lib/ lib/cmake/ExecuTorch/),
# consumed by anira via find_package(executorch CONFIG). Called by the root CMake
# orchestrator (cmake/ExternalEngine.cmake) and reused by CI.
#
# Unlike libtorch/onnx there is NO prebuilt source mode: PyTorch ships ExecuTorch only as
# Python wheels (AOT exporter) + mobile prebuilts, never a desktop C++ runtime archive, so
# every desktop leg is built from source. The <source>/<url> args are accepted for a
# uniform stage.sh signature but only `build` is supported.
#
# Usage: stage.sh <platform> <arch> <config> <kind> <source> <staging> [url] [flavor]
#   <platform> macos|linux|windows   <arch> x86_64|aarch64|arm64
#   <config>   Release                <kind> static
#   <source>   build                  <staging> output prefix
#   [url]      ignored (no prebuilt desktop runtime upstream)
#   [flavor]   GPU variant (docs/gpu-support.md): coreml (macOS -gpu) | vulkan (Linux -gpu)
set -euo pipefail

PLATFORM="${1:?platform}"; ARCH="${2:?arch}"; CONFIG="${3:?config}"; KIND="${4:?kind}"
SOURCE="${5:?source}"; ST="${6:?staging dir}"; URL="${7:-}"; FLAVOR="${8:-}"
HERE="$(cd "$(dirname "$0")" && pwd)"

if [ "$SOURCE" != "build" ]; then
  echo "ERROR: executorch supports only source=build (no upstream prebuilt desktop runtime); got '$SOURCE'" >&2
  exit 1
fi

bash "$HERE/build-executorch.sh" "$PLATFORM" "$ARCH" "$ST" "${FLAVOR:-none}"

echo "staged executorch ($PLATFORM/$ARCH/$KIND/$SOURCE${FLAVOR:+/$FLAVOR}) -> $ST"
