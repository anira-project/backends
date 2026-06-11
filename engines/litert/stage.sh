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
  # Force INT api levels — the runner preset ANDROID_SDK_API_LEVEL can be a float (e.g. 37.0),
  # which android_sdk_repository rejects ("expected int for api_level, got 37.0").
  export TF_SET_ANDROID_WORKSPACE=1 \
         ANDROID_SDK_HOME="${ANDROID_SDK_ROOT:-${ANDROID_HOME:?ANDROID SDK not found}}" \
         ANDROID_NDK_API_LEVEL=24 \
         ANDROID_SDK_API_LEVEL=34 \
         ANDROID_BUILD_TOOLS_VERSION="${ANDROID_BUILD_TOOLS_VERSION:-34.0.0}"
else
  export TF_SET_ANDROID_WORKSPACE=0
fi
# NB: `yes "" |` feeds defaults, but `yes` gets SIGPIPE (exit 141) when configure.py closes the
# pipe — which `set -o pipefail` would wrongly treat as failure. Disable pipefail for this pipe so
# only configure.py's own exit code counts.
( cd "$SRC" && chmod +x configure.py && { set +o pipefail; yes "" | python3 configure.py; } )

# Per-platform config (from LiteRT's .bazelrc / CI). CPU-only: GPU + NPU off.
case "$PLATFORM" in
  linux)   cfg=(--config=bulk_test_cpu) ;;
  macos)   if [ "$ARCH" = "arm64" ]; then cfg=(--config=macos_arm64 --config=bulk_test_cpu)
           else cfg=(--config=bulk_test_cpu --cpu=darwin_x86_64); fi ;;  # no macos_x86_64 config exists
  android) cfg=(--config="android_${ARCH%-v8a}") ;;                  # android_arm64 / android_x86_64
  ios)     cfg=(--config=ios_arm64) ;;
  windows) cfg=(--config=windows) ;;
  *) echo "ERROR: unknown platform '$PLATFORM'"; exit 1 ;;
esac

# bazelisk picks the repo-pinned Bazel from .bazelversion.
( cd "$SRC" && bazel build "${cfg[@]}" \
    --define=litert_disable_gpu=true --define=litert_disable_npu=true \
    //litert/c:litert_runtime_c_api_shared_lib )

# Headers: the C API needs litert/c/*.h plus a GENERATED litert/build_common/build_config.h
# (not in the source tree). Use the official litert_cc_sdk.zip header set — uniform across
# platforms (desktop build / android+iOS repackage) — and synthesize the CPU-only build_config.h
# from its .in template (just two toggles: DISABLE_GPU/DISABLE_NPU).
mkdir -p "$ST/include/litert/build_common" "$ST/lib"
sdk="$HERE/litert_cc_sdk"
if [ ! -d "$sdk/litert/c" ]; then
  curl -fsSL "https://github.com/google-ai-edge/LiteRT/releases/download/v${VER}/litert_cc_sdk.zip" -o "$HERE/litert_cc_sdk.zip"
  ( cd "$HERE" && cmake -E tar xf litert_cc_sdk.zip )   # -> $HERE/litert_cc_sdk/
fi
( cd "$sdk" && find litert/c -name '*.h' | while IFS= read -r h; do
    mkdir -p "$ST/include/$(dirname "$h")"; cp "$h" "$ST/include/$h"
  done )
cat > "$ST/include/litert/build_common/build_config.h" <<'EOF'
#ifndef LITERT_BUILD_COMMON_BUILD_CONFIG_H_
#define LITERT_BUILD_COMMON_BUILD_CONFIG_H_
#define LITERT_BUILD_CONFIG_DISABLE_GPU 1
#define LITERT_BUILD_CONFIG_DISABLE_NPU 1
#if LITERT_BUILD_CONFIG_DISABLE_GPU
#define LITERT_DISABLE_GPU
#endif
#if LITERT_BUILD_CONFIG_DISABLE_NPU
#define LITERT_DISABLE_NPU
#endif
#endif  // LITERT_BUILD_COMMON_BUILD_CONFIG_H_
EOF
# bazel-bin is a SYMLINK into the bazel cache — follow it (-L). The C API shared lib lands at
# bazel-bin/litert/c/libLiteRt.{so,dylib} (LiteRt.dll on Windows).
lib="$(find -L "$SRC/bazel-bin" -maxdepth 6 \( -name 'libLiteRt.so' -o -name 'libLiteRt.dylib' -o -name 'libLiteRt.dll' -o -name 'LiteRt.dll' \) 2>/dev/null | head -1)"
[ -n "$lib" ] || { echo "ERROR: libLiteRt not found under $SRC/bazel-bin"; ls -la "$SRC/bazel-bin/litert/c" 2>/dev/null | head -20; exit 1; }
cp -L "$lib" "$ST/lib/"
echo "staged litert ($PLATFORM/$ARCH/$KIND) -> $ST"
