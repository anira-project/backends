#!/usr/bin/env bash
# Build static onnxruntime (FULL op set, CPU provider) from source for one target,
# leaving the component .a/.lib for shared/bundle-static.sh to merge into one lib.
#
# Ports olilarkin/ort-builder's recipe MINUS the op-reduction (no --minimal_build /
# --include_ops_by_config / --enable_reduced_operator_type_support / --disable_ml_ops),
# so every operator ships and any model works.
#
# Usage: build-ort.sh <platform> <arch> <config> <build-dir>
#   <platform>  macos | linux | windows | android | ios | ios-sim
#   <arch>      x86_64 | arm64 | aarch64 | arm64-v8a (android ABI)
#   <config>    Release | Debug      (Windows ships both; others Release)
set -euo pipefail

PLATFORM="${1:?platform}"; ARCH="${2:?arch}"; CONFIG="${3:-Release}"; OUT="${4:-build}"
HERE="$(cd "$(dirname "$0")" && pwd)"
VER="$(tr -d '[:space:]' < "$HERE/VERSION")"

# onnxruntime source at the pinned version; build.py FetchContents the rest.
SRC="$HERE/onnxruntime-src"
if [ ! -d "$SRC/.git" ]; then
  git clone --depth 1 --branch "v${VER}" https://github.com/microsoft/onnxruntime "$SRC"
fi

ARGS=(
  --build_dir "$OUT"
  --config "$CONFIG"
  --parallel
  --skip_tests
  --compile_no_warning_as_error
  # Force re2 to build from source on every platform. Otherwise FetchContent's
  # FIND_PACKAGE_ARGS picks up a prebuilt re2 (e.g. vcpkg's on the Windows runners),
  # so no re2 build target is generated and the force-build below fails (MSB1009) —
  # and a prebuilt re2 wouldn't be in our static bundle anyway. (No-op on Linux/macOS,
  # which already build it from source.)
  #
  # onnxruntime_ENABLE_MEMLEAK_CHECKER: build.py turns this ON for Debug, which makes
  # the process abort at exit over onnxruntime's never-freed global singletons — i.e.
  # a Debug lib that crashes on normal teardown (smoke prints PASS, then exits 127).
  # It's an internal test aid; force OFF so the shipped Debug lib exits cleanly.
  #
  # onnxruntime_ENABLE_LTO=OFF: pin LTO off so MSVC never adds /GL + /LTCG (which
  # bloat the Windows static libs — the reason ort-builder ships ltcg_patch_for_windows).
  # In 1.26 /GL is gated entirely on this flag (cmake/adjust_global_compile_flags.cmake),
  # so this *is* the patch's net effect — the literal patch no longer applies (the
  # forced-LTO block it deletes was removed upstream). Explicit here, not build.py's default.
  --cmake_extra_defines onnxruntime_BUILD_UNIT_TESTS=OFF CMAKE_DISABLE_FIND_PACKAGE_re2=ON onnxruntime_ENABLE_MEMLEAK_CHECKER=OFF onnxruntime_ENABLE_LTO=OFF
)

case "$PLATFORM" in
  macos)
    # Keep system packages (Homebrew abseil/protobuf/flatbuffers) out of the build so
    # onnxruntime uses its own bundled versions — else find_package picks them up and
    # generated headers clash (protobuf "undeclared Arena", flatbuffers version assert).
    # ORT_IGNORE_PATHS adds machine-specific prefixes (e.g. a local Android SDK).
    # IGNORE_PATH covers find_library/find_path (abseil/protobuf); IGNORE_PREFIX_PATH
    # covers find_package CONFIG mode (flatbuffers_DIR) — both needed.
    IGNORE="/opt/homebrew;/usr/local${ORT_IGNORE_PATHS:+;$ORT_IGNORE_PATHS}"
    ARGS+=(--cmake_extra_defines "CMAKE_OSX_ARCHITECTURES=$ARCH" "CMAKE_OSX_DEPLOYMENT_TARGET=11.0" \
           "CMAKE_IGNORE_PATH=$IGNORE" "CMAKE_IGNORE_PREFIX_PATH=$IGNORE")
    ;;
  linux) ;;     # native arch
  windows) ;;   # arch from the MSVC env / host
  android)
    # https://onnxruntime.ai/docs/build/android.html — arch is the ABI (arm64-v8a / x86_64)
    : "${ANDROID_NDK_HOME:?ANDROID_NDK_HOME not set}"
    ARGS+=(--android --android_abi "$ARCH" --android_api 27 --android_ndk_path "$ANDROID_NDK_HOME"
           ${ANDROID_SDK_ROOT:+--android_sdk_path "$ANDROID_SDK_ROOT"})
    ;;
  ios)
    ARGS+=(--ios --use_xcode --apple_sysroot iphoneos --osx_arch "$ARCH" --apple_deploy_target 13.0 --build_apple_framework)
    ;;
  ios-sim)
    ARGS+=(--ios --use_xcode --apple_sysroot iphonesimulator --osx_arch "$ARCH" --apple_deploy_target 13.0 --build_apple_framework)
    ;;
  *) echo "ERROR: unknown platform '$PLATFORM'"; exit 1 ;;
esac

echo "+ build.py ${ARGS[*]}"
"${PYTHON:-python3}" "$SRC/tools/ci_build/build.py" "${ARGS[@]}"

# re2 is declared EXCLUDE_FROM_ALL and only *include*-attached to onnxruntime
# (cmake/onnxruntime_providers_cpu.cmake: onnxruntime_add_include_to_target ... re2::re2)
# on every non-WinML target — so the normal build NEVER compiles it. onnxruntime's
# shared lib tolerates the resulting undefined re2 symbols, but our STATIC bundle
# needs the objects, so force-build the target to emit libre2.a for bundling.
echo "+ force-build re2 (static bundle needs libre2.a / re2.lib)"
if [ "$PLATFORM" = "windows" ]; then
  # VS generator: `cmake --build --target re2` invokes `msbuild re2.vcxproj` as a
  # bare name from the binary-dir root, but the project lives in _deps/re2-build/
  # (MSB1009). re2 is fetched from source (CMAKE_DISABLE_FIND_PACKAGE_re2=ON +
  # onnxruntime_USE_VCPKG=OFF), so build the project by its real path instead.
  vcxproj="$(find "$OUT/$CONFIG" -name re2.vcxproj | head -1)"
  [ -n "$vcxproj" ] || { echo "ERROR: re2.vcxproj not found under $OUT/$CONFIG"; exit 1; }
  echo "  msbuild $vcxproj ($CONFIG)"
  MSYS_NO_PATHCONV=1 MSBuild.exe "$(cygpath -w "$vcxproj")" -p:Configuration="$CONFIG" -m -nologo
else
  cmake --build "$OUT/$CONFIG" --config "$CONFIG" --target re2
fi

echo "onnxruntime $VER ($PLATFORM/$ARCH/$CONFIG) built -> $OUT/$CONFIG"
