#!/usr/bin/env bash
# Build a STATIC, CPU-first ExecuTorch runtime from source for ONE desktop/Android target
# and stage it as a flat include/ + lib/libexecutorch.a tree — ONE merged archive, like the
# onnxruntime/litert/tflite static packages, that anira links on-demand with no CMake
# package and no force-load (see merge-static.sh for how the kernel/backend registrations
# survive that).
#
# Why from source (no repackage leg like libtorch/onnx): PyTorch publishes ExecuTorch
# only as Python wheels (the AOT exporter) plus mobile prebuilts (iOS .xcframework /
# Android .aar). There is NO upstream prebuilt desktop C++ runtime archive to repackage,
# so every desktop leg is built here.
#
# "Generic, full op set" (the neural_tilde approach): we link the WHOLE optimized CPU
# kernel library (optimized_native_cpu_ops_lib) + XNNPACK, NOT a per-model selective
# build. One package loads any .pte.
#
# CPU by default: XNNPACK (optimized CPU) + the portable/optimized/quantized ATen kernels on
# every platform, and nothing else in the default package. With the registrations pre-linked
# into the archive a delegate is either registered for every consumer or absent (there is no
# "present but inert" state) — which is exactly why GPU delegates ship ONLY in the separate
# -gpu variant archives (accel= below): the delegate's register_backend() TU joins the
# pre-linked blob through merge-static.sh's MERGE_DELEGATES.
#
# Usage: build-executorch.sh <platform> <arch> <staging-dir> [accel]
#   <platform>  macos | linux | windows | android
#   <arch>      x86_64 | aarch64 | arm64 (android: the ABI, arm64-v8a | x86_64)
#   <staging>   output prefix; gets include/ lib/libexecutorch.a (windows: lib/executorch.lib
#               + lib/executorch_registrations.lib)
#   <accel>     none (default) | coreml | vulkan. GPU delegates ship ONLY in the separate
#               -gpu variant archives — the default package is CPU-only.
#               coreml = macOS -gpu: CoreML + MPS delegates (+ MLX on arm64, which floors
#                        the deployment target at 14.0 — the CPU default stays at 12.0).
#               vulkan = Linux x86_64 -gpu (experimental): cross-vendor GPU delegate;
#                        needs glslc at build time only (loader is dlopen'd via volk).
#
# NOTE: like the libtorch/onnx/litert from-source recipes, this is expected to need a few
# CI rounds to converge per platform. Flags below follow ExecuTorch's own platform presets
# (tools/cmake/preset/{apple_common,linux,windows}.cmake at the pinned tag).
set -euo pipefail

PLATFORM="${1:?platform}"; ARCH="${2:?arch}"; ST="${3:?staging dir}"; ACCEL="${4:-none}"
case "$ACCEL" in
  none) ;;
  coreml) [ "$PLATFORM" = "macos" ] || { echo "ERROR: accel=coreml is macOS-only"; exit 1; } ;;
  vulkan) { { [ "$PLATFORM" = "linux" ] && [ "$ARCH" = "x86_64" ]; } || [ "$PLATFORM" = "android" ]; } || \
          { echo "ERROR: accel=vulkan is Linux-x86_64 or Android only"; exit 1; } ;;
  *) echo "ERROR: unknown accel '$ACCEL'"; exit 1 ;;
esac
HERE="$(cd "$(dirname "$0")" && pwd)"
VER="$(tr -d '[:space:]' < "$HERE/VERSION")"

# --- Source (recursive: ExecuTorch vendors XNNPACK, flatcc, pthreadpool, cpuinfo, etc.
# as submodules; --shallow-submodules keeps the checkout small) -----------------
# Windows: ExecuTorch (like PyTorch) ships deeply nested submodule paths that can exceed
# the 260-char MAX_PATH limit; enable git long-path support. No-op on macOS/Linux.
[ "$PLATFORM" = "windows" ] && git config --global core.longpaths true

# ExecuTorch's CMakeLists.txt refuses to configure unless its source tree is named exactly
# `executorch` (upstream issue 6475). It also puts the source tree's PARENT on the compiler
# include path (so `#include <executorch/...>` resolves), so that parent must NOT contain a
# file that case-insensitively matches a stdlib header — our engine dir has a `VERSION` file,
# which on macOS/Windows collides with `#include <version>` (C++20). Nest the clone under a
# clean `src/` dir: leaf stays `executorch`, and the parent (src/) holds nothing else.
SRC="$HERE/src/executorch"
mkdir -p "$HERE/src"
if [ ! -d "$SRC/.git" ]; then
  git clone --depth 1 --recurse-submodules --shallow-submodules \
    --branch "v${VER}" https://github.com/pytorch/executorch "$SRC"
else
  # A cached checkout may predate a submodule bump; resync defensively.
  ( cd "$SRC" && git submodule sync --recursive \
      && git submodule update --init --recursive --depth 1 )
fi

# --- Python build deps. ExecuTorch's CMake codegen (kernel bindings / selective-build
# machinery in tools/cmake/Codegen.cmake) imports the `executorch` python package and
# pyyaml at configure time. Install the repo's build requirements and put the source tree
# on PYTHONPATH so `import executorch.codegen...` resolves WITHOUT building the wheel
# (codegen is pure-python + yaml; no compiled extension needed just to generate op libs).
python -m pip install --upgrade pip
# requirements-dev.txt pins lintrunner (a Rust/maturin lint tool) which has no win-arm64
# wheel and fails to build there; it's unused by the codegen, so strip it. Everything else
# (cmake/pyyaml/zstd/certifi/...) the codegen + resolve_buck need stays.
if [ -f "$SRC/requirements-dev.txt" ]; then
  grep -viE 'lintrunner' "$SRC/requirements-dev.txt" > "$SRC/.et-build-reqs.txt"
  python -m pip install -r "$SRC/.et-build-reqs.txt"
fi
python -m pip install pyyaml setuptools wheel
export PYTHONPATH="$SRC${PYTHONPATH:+:$PYTHONPATH}"

# ExecuTorch's configure resolves ATen headers from an INSTALLED `torch` (EXECUTORCH_
# BUILD_KERNELS_OPTIMIZED -> CMakeLists.txt:602 find_package_torch_headers ->
# tools/cmake/Utils.cmake get_torch_base_path, which runs find_spec('torch') and reads
# <torch>/include). We never LINK libtorch — only its C++ headers are needed at build time.
# ExecuTorch v1.3.1 pins torch==2.12.0 (install_requirements.py).
TORCH_PIN="2.12.0"
if [ "$PLATFORM" = "macos" ] && [ "$ARCH" = "x86_64" ]; then
  # PyTorch ships no x86_64-macOS wheel since 2.3.0, so build libtorch from source on the
  # macos-15-intel runner exactly like engines/libtorch/build-libtorch.sh — but only to
  # GENERATE torch/include. find_spec('torch') merely LOCATES the package (never imports
  # its _C extension), so the pytorch source root on PYTHONPATH is enough: it resolves to
  # <pytorch>/torch, whose include/ build_libtorch.py has populated with the ATen headers.
  PT="$HERE/pytorch-src"
  if [ ! -d "$PT/.git" ]; then
    git clone --depth 1 --recurse-submodules --shallow-submodules \
      --branch "v${TORCH_PIN}" https://github.com/pytorch/pytorch "$PT"
  fi
  [ -f "$PT/requirements-build.txt" ] && python -m pip install -r "$PT/requirements-build.txt"
  python -m pip install pyyaml typing_extensions setuptools numpy
  rm -f "$PT/build/CMakeCache.txt"   # sticky cache vars from a prior config (see build-libtorch.sh)
  # Route PyTorch's compiles through sccache too — this from-source build is the slowest leg by
  # far, so caching it across runs is the biggest win. PyTorch forwards CMAKE_*_COMPILER_LAUNCHER.
  PT_SCCACHE=""
  command -v sccache >/dev/null 2>&1 && \
    PT_SCCACHE="CMAKE_C_COMPILER_LAUNCHER=sccache CMAKE_CXX_COMPILER_LAUNCHER=sccache"
  # Env scoped to the subshell so PyTorch's BUILD_* / USE_* don't leak into ExecuTorch's
  # own cmake below. CMAKE_POLICY_VERSION_MINIMUM: old vendored protobuf needs the <3.5
  # policy floor under CMake 4.x. USE_NATIVE_ARCH=0: avoid Apple-Clang-rejected -mavx512fp16.
  # PYTHONPATH="": drop the ExecuTorch source root we exported above — it also has a top-level
  # `tools/` package that otherwise shadows PyTorch's, breaking `import tools.build_pytorch_libs`.
  ( cd "$PT" \
    && PYTHONPATH="" \
       CMAKE_POLICY_VERSION_MINIMUM=3.5 \
       USE_CUDA=0 USE_ROCM=0 USE_DISTRIBUTED=0 USE_MPS=0 \
       BUILD_TEST=0 BUILD_PYTHON=0 BUILD_SHARED_LIBS=1 \
       USE_MKLDNN=1 USE_NATIVE_ARCH=0 \
       CMAKE_OSX_ARCHITECTURES=x86_64 MACOSX_DEPLOYMENT_TARGET=12.0 \
       env ${PT_SCCACHE} python tools/build_libtorch.py )
  [ -d "$PT/torch/include" ] || \
    { echo "ERROR: pytorch source build produced no torch/include headers under $PT"; exit 1; }
  # ExecuTorch's kernel codegen imports torchgen and reads torchgen/packaged/ATen/native/
  # {native_functions,tags}.yaml. That dir is populated by PyTorch's setup.py packaging (a
  # plain copy from aten/src/ATen/native/), which build_libtorch.py (BUILD_PYTHON=0) skips —
  # so replicate the copy. Without it codegen dies with FileNotFoundError on native_functions.yaml.
  mkdir -p "$PT/torchgen/packaged/ATen/native"
  cp "$PT/aten/src/ATen/native/native_functions.yaml" "$PT/torchgen/packaged/ATen/native/"
  cp "$PT/aten/src/ATen/native/tags.yaml"             "$PT/torchgen/packaged/ATen/native/"
  export PYTHONPATH="$PT${PYTHONPATH:+:$PYTHONPATH}"
else
  python -m pip install "torch==${TORCH_PIN}" \
    --extra-index-url https://download.pytorch.org/whl/test/cpu
fi

# Per-target build/install dirs: the iOS device + simulator slices run in the SAME job
# (ios.sh builds both), so they must not share one cmake-out, and a tag suffix also keeps
# desktop reconfigure clean across cached source.
_tag="${PLATFORM}-${ARCH}"
INSTALL="$SRC/cmake-out-install-$_tag"
BUILD="$SRC/cmake-out-$_tag"
rm -rf "$INSTALL"

# --- Common config: static runtime, full CPU op set + XNNPACK, no runner/pybind/tests ---
# These mirror the ON flags from ExecuTorch's platform presets, stated explicitly so a
# preset rename upstream can't silently drop one. extension_module/tensor are anira's
# load+run entry points; *_evalue/runner_util back the Module convenience API.
ET_FLAGS=(
  -DCMAKE_BUILD_TYPE=Release
  -DCMAKE_INSTALL_PREFIX="$INSTALL"
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON
  -DBUILD_TESTING=OFF
  -DEXECUTORCH_BUILD_EXECUTOR_RUNNER=OFF
  -DEXECUTORCH_BUILD_PYBIND=OFF
  -DEXECUTORCH_ENABLE_PROGRAM_VERIFICATION=ON
  -DEXECUTORCH_BUILD_EXTENSION_DATA_LOADER=ON
  -DEXECUTORCH_BUILD_EXTENSION_FLAT_TENSOR=ON
  # 1.3.1: EXTENSION_MODULE requires NAMED_DATA_MAP (enforced by preset.cmake)
  -DEXECUTORCH_BUILD_EXTENSION_NAMED_DATA_MAP=ON
  -DEXECUTORCH_BUILD_EXTENSION_MODULE=ON
  -DEXECUTORCH_BUILD_EXTENSION_TENSOR=ON
  -DEXECUTORCH_BUILD_EXTENSION_RUNNER_UTIL=ON
  -DEXECUTORCH_BUILD_EXTENSION_EVALUE_UTIL=ON
  -DEXECUTORCH_BUILD_KERNELS_OPTIMIZED=ON
  -DEXECUTORCH_BUILD_KERNELS_QUANTIZED=ON
  -DEXECUTORCH_BUILD_XNNPACK=ON
  -DEXECUTORCH_XNNPACK_ENABLE_WEIGHT_CACHE=ON
)

# The Vulkan delegate compiles its shaders with glslc at build time. ExecuTorch 1.3.1's int8
# shaders need a glslang that knows GL_EXT_integer_dot_product (dotPacked4x8AccSatEXT):
# Ubuntu 24.04's apt glslc (shaderc 2023.8) rejects it and the Android NDK's glslc is also
# incompatible (per upstream's own cmake/ShaderLibrary.cmake warning) — so probe the ACTUAL
# requirement and install LunarG's current shaderc on the (Ubuntu) runner if needed. Used by the
# Linux and the Android (NDK cross-compile on an Ubuntu runner) -gpu legs alike.
ensure_glslc() {
  glslc_ok() {
    command -v glslc >/dev/null 2>&1 || return 1
    local probe; probe="$(mktemp /tmp/et-glslc-probe-XXXXXX.comp)"
    printf '#version 450\n#extension GL_EXT_integer_dot_product : require\nvoid main(){}\n' > "$probe"
    glslc -fshader-stage=compute --target-env=vulkan1.1 "$probe" -o /dev/null 2>/dev/null
    local rc=$?; rm -f "$probe"; return $rc
  }
  if ! glslc_ok; then
    if command -v sudo >/dev/null 2>&1 && command -v apt-get >/dev/null 2>&1; then
      curl -fsSL https://packages.lunarg.com/lunarg-signing-key-pub.asc \
        | sudo tee /etc/apt/trusted.gpg.d/lunarg.asc >/dev/null
      echo "deb https://packages.lunarg.com/vulkan noble main" \
        | sudo tee /etc/apt/sources.list.d/lunarg-vulkan-noble.list >/dev/null
      sudo apt-get update -qq && sudo apt-get install -y -qq shaderc
    fi
    glslc_ok || { echo "ERROR: accel=vulkan needs a glslc with GL_EXT_integer_dot_product support on PATH"; exit 1; }
  fi
}

case "$PLATFORM" in
  macos)
    # Default package is CPU-only at deployment target 12.0. The -gpu variant (accel=coreml)
    # adds the CoreML delegate, and on arm64 also MLX — whose backends/mlx/CMakeLists.txt
    # hard-requires >=14.0, so ONLY the arm64 -gpu package floors at macOS 14+; every other
    # macOS package stays 12.0. The delegates' register_backend() TUs join the pre-linked
    # blob at the merge step below (MERGE_DELEGATES).
    MACVER=12.0
    if [ "$ACCEL" = "coreml" ]; then
      ET_FLAGS+=(
        -DEXECUTORCH_BUILD_COREML=ON   # ANE/GPU; embeds the CoreML model in the .pte
        # MPS delegate too: CoreML and MPS serve different models (ANE-compiled vs
        # direct Metal kernels) and the .pte's export-time partitioning picks — both
        # being present means any Apple-exported .pte works with this one -gpu
        # archive, matching the iOS -gpu xcframework which ships both as well.
        -DEXECUTORCH_BUILD_MPS=ON
      )
      if [ "$ARCH" = "arm64" ]; then
        MACVER=14.0
        # MLX (Apple-Silicon GPU) is arm64-only; there is no Intel-mac MLX. Bundles an
        # mlx.metallib that must ship alongside the lib (staging step below keys on
        # this shell var).
        EXECUTORCH_BUILD_MLX=ON
        ET_FLAGS+=(-DEXECUTORCH_BUILD_MLX=ON)
      fi
    fi
    export MACOSX_DEPLOYMENT_TARGET="$MACVER"
    ET_FLAGS+=(
      -DCMAKE_OSX_ARCHITECTURES="$ARCH"
      -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACVER"
    )
    ;;
  linux)
    # Default: CPU-only (XNNPACK + optimized ATen kernels). The -gpu variant (accel=vulkan)
    # adds the cross-vendor Vulkan delegate (experimental): shaders are compiled at build
    # time with glslc; at runtime the delegate loads libvulkan via volk (dlopen), so the
    # package adds NO hard runtime dependency — without a Vulkan driver or a
    # vulkan-partitioned .pte it behaves exactly like the CPU package.
    if [ "$ACCEL" = "vulkan" ]; then
      # ExecuTorch 1.3.1's int8 shaders need a glslang that knows
      # GL_EXT_integer_dot_product (dotPacked4x8AccSatEXT). Ubuntu 24.04's apt glslc
      # (shaderc 2023.8) rejects it — "'#extension' : extension not supported" — so
      # probe the ACTUAL requirement and install LunarG's current shaderc if the
      # ambient glslc can't do it. (The Android NDK's glslc is also incompatible,
      # per upstream's own cmake/ShaderLibrary.cmake warning.)
      ensure_glslc
      ET_FLAGS+=(-DEXECUTORCH_BUILD_VULKAN=ON)
    fi ;;
  windows)
    # MSVC (cl) via the workflow's msvc-dev-cmd env + Ninja. We disable the LLM/custom
    # kernels (ExecuTorch warns those need -T ClangCL on MSVC); core + XNNPACK + optimized
    # kernels build fine with cl. Same Vulkan TODO as Linux applies.
    export CMAKE_GENERATOR=Ninja
    # win-arm64: XNNPACK keeps its ARM FP16/BF16 micro-kernels on for any arm64 target, but
    # those .c files #include <arm_fp16.h>, a Clang/GCC-ARM header MSVC's arm64 cl lacks
    # (fatal C1083). Disable them explicitly (-D overrides XNNPACK's OPTION default); fp16
    # ops fall back to fp32 paths. CPU-first anira doesn't need fp16-accelerated kernels here.
    [ "$ARCH" = "arm64" ] && ET_FLAGS+=(
      -DXNNPACK_ENABLE_ARM_FP16_VECTOR=OFF
      -DXNNPACK_ENABLE_ARM_FP16_SCALAR=OFF
      -DXNNPACK_ENABLE_ARM_BF16=OFF
    )
    # Upstream bug (third-party/CMakeLists.txt): flatbuffers_ep declares its byproduct as
    # `<INSTALL_DIR>/bin/flatc` (no extension), but the imported flatc target's Windows
    # location is `flatc.exe`. Under Ninja the schema codegen then depends on flatc.exe with
    # no rule producing it ("missing and no known rule to make it"). Add the .exe byproduct.
    # Idempotent: the regex won't re-match a line already ending in flatc.exe (cached source).
    sed -i 's|\(<INSTALL_DIR>/bin/flatc\)$|\1.exe|' "$SRC/third-party/CMakeLists.txt"
    # Many kernel/config CMakeLists set `_common_compile_options -Wno-deprecated-declarations`,
    # a GCC/Clang flag MSVC rejects (cl: D8021 invalid numeric argument). /wd4996 is the MSVC
    # equivalent (already used elsewhere). Swap it tree-wide so every target builds under cl.
    # Idempotent: once replaced there's no `-Wno-...` left to match (survives the cached source).
    find "$SRC" -name CMakeLists.txt -print0 \
      | xargs -0 sed -i 's|-Wno-deprecated-declarations|/wd4996|g'
    # Kernel ops declare `name` for ET_SWITCH error strings — but some macros also pass it as a
    # template non-type arg (&name), which on MSVC requires STATIC STORAGE + constexpr or it's
    # "not usable in constant expressions" (C2131). Block-scope `constexpr auto name` (no static)
    # fails that, and a plain `const char*` fails it too. Normalize every variant tree-wide to
    # `static constexpr auto name =`. Idempotent (already-correct form maps to itself).
    grep -rlZ -E '(static )?(const char\* const|constexpr auto) name =' "$SRC" 2>/dev/null \
      | xargs -0 --no-run-if-empty sed -E -i 's#(static )?(const char\* const|constexpr auto) name =#static constexpr auto name =#g'
    ;;
  android)
    # NDK cross-compile; ARCH is the ABI (arm64-v8a | x86_64). Default: CPU-only (XNNPACK +
    # optimized/portable/quantized kernels). Host torch wheel (linux x86_64) supplies the ATen
    # headers — fine for cross-compile (headers are arch-independent). NDK provided by
    # setup-toolchain (toolchain: android -> ANDROID_NDK_HOME).
    : "${ANDROID_NDK_HOME:?ANDROID_NDK_HOME not set (needs toolchain: android)}"
    ET_FLAGS+=(
      -DCMAKE_TOOLCHAIN_FILE="$ANDROID_NDK_HOME/build/cmake/android.toolchain.cmake"
      -DANDROID_ABI="$ARCH"
      -DANDROID_PLATFORM=android-27
    )
    # -gpu (accel=vulkan): the Vulkan delegate — Android is its home platform. Shaders compile
    # with the host glslc at build time (ensure_glslc: LunarG shaderc, not the NDK's); at
    # runtime the delegate loads libvulkan via volk, so the package adds no hard dependency.
    # Its registration joins the merged archive through MERGE_DELEGATES (below), as on Linux.
    if [ "$ACCEL" = "vulkan" ]; then
      ensure_glslc
      ET_FLAGS+=(-DEXECUTORCH_BUILD_VULKAN=ON)
    fi
    ;;
  # NOTE: iOS is NOT handled here. ios.sh builds it via ExecuTorch's own `ios`/`ios-simulator`
  # CMake presets (which build the host flatc/flatcc tools correctly during the cross-compile);
  # a hand-rolled ios-cmake toolchain here leaked the iOS SDK/deployment target into the host
  # tools and broke them. Keep this build path desktop/Android only.
  *) echo "ERROR: unknown platform '$PLATFORM'"; exit 1 ;;
esac

# Route compiles through sccache (the CI sets it up) so warm re-runs are fast. The shared
# stage-build action only wires this for tflite, so executorch compiled uncached — the big
# intel-mac PyTorch-from-source + ExecuTorch builds rebuilt from scratch every run. Skip on
# Windows: MSVC /Fd (pdb) trips sccache (same reason the shared action limits it to tflite).
if [ "$PLATFORM" != "windows" ] && command -v sccache >/dev/null 2>&1; then
  ET_FLAGS+=(-DCMAKE_C_COMPILER_LAUNCHER=sccache -DCMAKE_CXX_COMPILER_LAUNCHER=sccache)
fi

# A restored/cached build tree pins CMake cache vars from the PRIOR config; drop the cache
# so cmake re-detects against the current flags (objects + any compiler cache keep the
# rebuild incremental). No-op on a cold build. Mirrors build-libtorch.sh.
rm -f "$BUILD/CMakeCache.txt"

# The flatc/flatcc host-tool ExternalProjects don't survive an incremental rebuild from a
# RESTORED build-tree cache: their libs link, then a step fails silently ("subcommand failed",
# no error) — both Windows legs hit this deterministically off the cache. They install outputs
# back into the source tree (third-party/flatcc/{lib,bin}), so a cached copy collides on
# reinstall. Wipe their build state + in-source outputs so they rebuild clean each run; both
# are tiny, so the cost is negligible.
rm -rf "$BUILD/third-party/flatc_ep" "$BUILD/third-party/flatcc_ep" \
       "$SRC/third-party/flatcc/lib" "$SRC/third-party/flatcc/bin" 2>/dev/null || true

# Cap build parallelism by available RAM. At unlimited -j the optimized-kernel TUs (each
# pulling heavy ATen headers) use multiple GB apiece and OOM-kill the smaller runners — the
# macOS-arm64 and Linux legs died with "hosted runner lost communication ... starves it for
# CPU/Memory". Budget ~3 GB/job, floor 2, ceil core count. Big runners (intel-mac) still get
# full width; small ones (~7-16 GB) stay alive.
ncores=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)
if sysctl -n hw.memsize >/dev/null 2>&1; then
  memgb=$(( $(sysctl -n hw.memsize) / 1073741824 ))                                   # macOS
else
  memgb=$(( $(getconf _PHYS_PAGES 2>/dev/null || echo 0) * $(getconf PAGE_SIZE 2>/dev/null || echo 4096) / 1073741824 ))  # linux
fi
[ "${memgb:-0}" -lt 1 ] && memgb=8                       # unknown (e.g. git-bash) -> assume 8
BUILD_JOBS=$(( memgb / 3 )); [ "$BUILD_JOBS" -lt 2 ] && BUILD_JOBS=2
[ "$BUILD_JOBS" -gt "$ncores" ] && BUILD_JOBS=$ncores

echo "== building ExecuTorch ${VER} for ${PLATFORM}/${ARCH} (static, CPU + XNNPACK, accel=${ACCEL}${EXECUTORCH_BUILD_MLX:+ +MLX}); -j ${BUILD_JOBS} (cores=${ncores} mem=${memgb}GB) =="
cmake -S "$SRC" -B "$BUILD" "${ET_FLAGS[@]}"
cmake --build "$BUILD" -j "$BUILD_JOBS" --target install

# The install tree must carry the CMake package (lib/cmake/ExecuTorch/ExecuTorchTargets*.cmake):
# it is not shipped, but merge-static.sh reads the member list and the force-load set off it.
[ -f "$INSTALL/lib/cmake/ExecuTorch/executorch-config.cmake" ] || \
  { echo "ERROR: build produced no lib/cmake/ExecuTorch/executorch-config.cmake under $INSTALL"; exit 1; }

# Stage: headers as installed, and ONE merged archive instead of the 25-odd component
# libs + CMake package. (ExecuTorch 1.3.1 installs a few libs into the build tree instead
# of the prefix and bakes that absolute path into the export; merge-static.sh follows the
# exported locations, so those members are picked up from wherever they landed.)
rm -rf "$ST/include" "$ST/lib"; mkdir -p "$ST"
cp -R "$INSTALL/include" "$ST/include"
out="$ST/lib/libexecutorch.a"; [ "$PLATFORM" = "windows" ] && out="$ST/lib/executorch.lib"
# -gpu variants: the delegates' registration TUs join the pre-linked blob (they are
# EXCLUDE_LIBS in a default build — GPU is always a separate archive).
MERGE_DELEGATES=""; MERGE_EXTRA_ARCHIVES=""
case "$ACCEL" in
  coreml)
    MERGE_DELEGATES="coremldelegate mpsdelegate"
    if [ "${EXECUTORCH_BUILD_MLX:-}" = "ON" ]; then
      MERGE_DELEGATES="$MERGE_DELEGATES mlxdelegate"
      # libmlxdelegate.a references mlx::core::* from libmlx.a, which MLX's CMake builds as a
      # sub-dependency and installs WITHOUT an export (executorch-config.cmake find_library()s
      # it) — so ExecuTorchTargets.cmake never lists it. Hand it to the merge explicitly.
      MERGE_EXTRA_ARCHIVES="$(find "$INSTALL" "$BUILD" -name 'libmlx.a' -type f 2>/dev/null | head -1)"
      [ -n "$MERGE_EXTRA_ARCHIVES" ] || { echo "ERROR: MLX enabled but libmlx.a not found under $INSTALL / $BUILD"; exit 1; }
    fi ;;
  vulkan) MERGE_DELEGATES="vulkan_backend" ;;
esac
MERGE_DELEGATES="$MERGE_DELEGATES" MERGE_EXTRA_ARCHIVES="$MERGE_EXTRA_ARCHIVES" \
  bash "$HERE/merge-static.sh" "$PLATFORM" "$INSTALL" "$out"

# MLX sidecar: mlx.metallib holds the compiled Metal kernels the delegate loads at execute()
# time; it must ship next to the lib (executorch-config.cmake looks for it under lib/).
if [ "${EXECUTORCH_BUILD_MLX:-}" = "ON" ]; then
  metallib="$(find "$INSTALL" "$BUILD" -name 'mlx.metallib' -type f 2>/dev/null | head -1)"
  [ -n "$metallib" ] || { echo "ERROR: MLX enabled but no mlx.metallib found to bundle"; exit 1; }
  cp -f "$metallib" "$ST/lib/"; echo "bundled MLX kernels: $metallib -> $ST/lib/"
fi

echo "built + staged -> $ST"
( cd "$ST" && find . -maxdepth 2 | sort | sed 's/^/  /' )
