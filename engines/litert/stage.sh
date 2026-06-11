#!/usr/bin/env bash
# Build LiteRT's NATIVE C API (libLiteRt — LiteRt* symbols) from google-ai-edge/LiteRT via
# Bazel, CPU-only, and stage include/litert/c + lib/libLiteRt.{so,dylib,dll}. Distinct from the
# `tflite` engine (legacy TfLite* C API from tensorflow/lite/c). Called by the root CMake
# orchestrator (cmake/ExternalEngine.cmake) and reused by CI.
#
# Usage: stage.sh <platform> <arch> <config> <kind> <source> <staging> [url]
#   <platform> macos|linux|windows|android|ios   <arch> x86_64|arm64|aarch64|arm64-v8a
#   <kind> shared (static deferred)   <staging> output prefix (include/ + lib/)
#
# FIRST-PASS recipe — LiteRT's only all-platform build is Bazel, and Bazel cross-compile
# (esp. Windows/iOS) needs CI iteration. Targets/flags below follow the repo's CMAKE doc
# (CPU-only = GPU/NPU off) and its per-platform Bazel CI configs; expect to refine per leg.
set -euo pipefail

PLATFORM="${1:?platform}"; ARCH="${2:?arch}"; CONFIG="${3:-Release}"; KIND="${4:-shared}"
SOURCE="${5:-build}"; ST="${6:?staging dir}"
HERE="$(cd "$(dirname "$0")" && pwd)"
VER="$(tr -d '[:space:]' < "$HERE/VERSION")"

# Source at the pinned RELEASE tag (not main). Recursive: LiteRT vendors deps + tflite tree.
SRC="$HERE/litert-src"
if [ ! -d "$SRC/.git" ]; then
  git clone --depth 1 --branch "v${VER}" https://github.com/google-ai-edge/LiteRT "$SRC"
fi

# LiteRT/TF Bazel needs configure.py FIRST to generate the (host) CC toolchain — without it,
# "@@local_config_cc//:toolchain does not contain a toolchain for cpu". Run it non-interactively
# (env mirrors LiteRT's own CI). NOTE: their CI runs inside the ml-build Docker container with
# hermetic toolchains; bare-runner cross-builds (android/ios/windows) may need more here.
# sys.executable is the real interpreter path (.exe on Windows; `command -v python3` returns a
# no-.exe path there that configure.py rejects).
export PYTHON_BIN_PATH="$(python3 -c 'import sys; print(sys.executable)')"
export PYTHON_LIB_PATH="$(python3 -c 'import site; print(site.getsitepackages()[0])')"
export TF_NEED_ROCM=0 TF_NEED_CUDA=0 CC_OPT_FLAGS='-Wno-sign-compare'
if [ "$PLATFORM" = "android" ]; then
  : "${ANDROID_NDK_HOME:?ANDROID_NDK_HOME not set}"
  # configure.py's android workspace needs the SDK too (not just the NDK).
  export TF_SET_ANDROID_WORKSPACE=1 \
         ANDROID_SDK_HOME="${ANDROID_SDK_ROOT:-${ANDROID_HOME:?ANDROID SDK not found}}" \
         ANDROID_NDK_API_LEVEL=24 \
         ANDROID_SDK_API_LEVEL="${ANDROID_SDK_API_LEVEL:-33}" \
         ANDROID_BUILD_TOOLS_VERSION="${ANDROID_BUILD_TOOLS_VERSION:-34.0.0}"
else
  export TF_SET_ANDROID_WORKSPACE=0
fi
( cd "$SRC" && chmod +x configure.py && yes "" | python3 configure.py )

# Per-platform config (from LiteRT's .bazelrc / CI). CPU-only: GPU + NPU off.
case "$PLATFORM" in
  linux)   cfg=(--config=bulk_test_cpu) ;;
  macos)   cfg=(--config="macos_${ARCH}" --config=bulk_test_cpu) ;;  # macos_arm64 / macos_x86_64
  android) cfg=(--config="android_${ARCH%-v8a}") ;;                  # android_arm64 / android_x86_64
  ios)     cfg=(--config=ios_arm64) ;;
  windows) cfg=(--config=windows) ;;
  *) echo "ERROR: unknown platform '$PLATFORM'"; exit 1 ;;
esac

# bazelisk picks the repo-pinned Bazel from .bazelversion.
( cd "$SRC" && bazel build "${cfg[@]}" \
    --define=litert_disable_gpu=true --define=litert_disable_npu=true \
    //litert/c:litert_runtime_c_api_shared_lib )

# Stage the native C API headers + the shared lib.
mkdir -p "$ST/include/litert/c" "$ST/lib"
cp "$SRC"/litert/c/litert_*.h "$ST/include/litert/c/"
[ -d "$SRC/litert/c/options" ] && { mkdir -p "$ST/include/litert/c/options"; cp "$SRC"/litert/c/options/*.h "$ST/include/litert/c/options/" 2>/dev/null || true; }
lib="$(find "$SRC/bazel-bin" -maxdepth 4 -name 'libLiteRt.*' \( -name '*.so' -o -name '*.dylib' -o -name '*.dll' \) | head -1)"
[ -n "$lib" ] || { echo "ERROR: libLiteRt shared lib not found under $SRC/bazel-bin"; exit 1; }
cp "$lib" "$ST/lib/"
echo "staged litert ($PLATFORM/$ARCH/$KIND) -> $ST"
