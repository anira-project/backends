#!/usr/bin/env bash
# Build a STATIC, CPU-first ExecuTorch runtime from source for ONE desktop target,
# producing a find_package(executorch)-consumable package tree (include/ lib/
# lib/cmake/ExecuTorch/), the same path anira will use to link it.
#
# Why from source (no repackage leg like libtorch/onnx): PyTorch publishes ExecuTorch
# only as Python wheels (the AOT exporter) plus mobile prebuilts (iOS .xcframework /
# Android .aar). There is NO upstream prebuilt desktop C++ runtime archive to repackage,
# so every desktop leg is built here.
#
# "Generic, full op set" (the neural_tilde approach): we link the WHOLE optimized CPU
# kernel library (optimized_native_cpu_ops_lib) + XNNPACK, NOT a per-model selective
# build. One package loads any .pte. ExecuTorch's exported targets already carry
# -force_load via INTERFACE_LINK_OPTIONS, so op/backend static initializers register
# without extra whole-archive handling on the consumer side.
#
# CPU first, hardware later: XNNPACK (optimized CPU) + the portable/optimized ATen
# kernels are enabled on every platform. Apple delegates (CoreML, and MLX on arm64) are
# built in so the GPU/ANE path can be switched on later WITHOUT a runtime rebuild — but
# anira uses the CPU path for now. The cross-platform GPU delegate for Linux/Windows
# (Vulkan) is left as a follow-up; see the TODO below.
#
# Usage: build-executorch.sh <platform> <arch> <staging-dir>
#   <platform>  macos | linux | windows
#   <arch>      x86_64 | aarch64 | arm64
#   <staging>   output prefix; gets include/ lib/ (incl. lib/cmake/ExecuTorch/)
#
# NOTE: like the libtorch/onnx/litert from-source recipes, this is expected to need a few
# CI rounds to converge per platform. Flags below follow ExecuTorch's own platform presets
# (tools/cmake/preset/{apple_common,linux,windows}.cmake at the pinned tag).
set -euo pipefail

PLATFORM="${1:?platform}"; ARCH="${2:?arch}"; ST="${3:?staging dir}"
HERE="$(cd "$(dirname "$0")" && pwd)"
VER="$(tr -d '[:space:]' < "$HERE/VERSION")"

# --- Source (recursive: ExecuTorch vendors XNNPACK, flatcc, pthreadpool, cpuinfo, etc.
# as submodules; --shallow-submodules keeps the checkout small) -----------------
# Windows: ExecuTorch (like PyTorch) ships deeply nested submodule paths that can exceed
# the 260-char MAX_PATH limit; enable git long-path support. No-op on macOS/Linux.
[ "$PLATFORM" = "windows" ] && git config --global core.longpaths true

SRC="$HERE/executorch-src"
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
[ -f "$SRC/requirements-dev.txt" ]  && python -m pip install -r "$SRC/requirements-dev.txt"
python -m pip install pyyaml setuptools wheel
export PYTHONPATH="$SRC${PYTHONPATH:+:$PYTHONPATH}"

INSTALL="$SRC/cmake-out-install"
BUILD="$SRC/cmake-out"
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

case "$PLATFORM" in
  macos)
    export MACOSX_DEPLOYMENT_TARGET=12.0   # CoreML state APIs / std::filesystem floor
    ET_FLAGS+=(
      -DCMAKE_OSX_ARCHITECTURES="$ARCH"
      -DCMAKE_OSX_DEPLOYMENT_TARGET=12.0
      # Apple delegates — built in so the ANE/GPU path is ready WITHOUT a rebuild. anira
      # stays on CPU for now; these just have to be present in the package.
      -DEXECUTORCH_BUILD_COREML=ON          # ANE/GPU; embeds the CoreML model in the .pte
    )
    # MLX (Apple-Silicon GPU) is arm64-only; there is no Intel-mac MLX. Bundles an
    # mlx.metallib that must ship alongside the libs (handled in the staging step below).
    [ "$ARCH" = "arm64" ] && ET_FLAGS+=(-DEXECUTORCH_BUILD_MLX=ON)
    ;;
  linux)
    # CPU-only (XNNPACK + optimized ATen kernels). No CoreML/MLX off Apple.
    # TODO(hw-accel): add -DEXECUTORCH_BUILD_VULKAN=ON here as the cross-platform GPU
    # delegate once we move past CPU. Vulkan needs the Vulkan SDK + glslc on the runner.
    : ;;
  windows)
    # MSVC (cl) via the workflow's msvc-dev-cmd env + Ninja. We disable the LLM/custom
    # kernels (ExecuTorch warns those need -T ClangCL on MSVC); core + XNNPACK + optimized
    # kernels build fine with cl. Same Vulkan TODO as Linux applies.
    export CMAKE_GENERATOR=Ninja
    ;;
  *) echo "ERROR: unknown platform '$PLATFORM'"; exit 1 ;;
esac

# A restored/cached build tree pins CMake cache vars from the PRIOR config; drop the cache
# so cmake re-detects against the current flags (objects + any compiler cache keep the
# rebuild incremental). No-op on a cold build. Mirrors build-libtorch.sh.
rm -f "$BUILD/CMakeCache.txt"

echo "== building ExecuTorch ${VER} for ${PLATFORM}/${ARCH} (static, CPU + XNNPACK${EXECUTORCH_BUILD_MLX:+ +MLX}) =="
cmake -S "$SRC" -B "$BUILD" "${ET_FLAGS[@]}"
cmake --build "$BUILD" -j --target install

# The install tree must carry the CMake package (lib/cmake/ExecuTorch/executorch-config.cmake
# + ExecuTorchTargets.cmake) — that is what find_package(executorch CONFIG) resolves.
[ -f "$INSTALL/lib/cmake/ExecuTorch/executorch-config.cmake" ] || \
  { echo "ERROR: build produced no lib/cmake/ExecuTorch/executorch-config.cmake under $INSTALL"; exit 1; }

mkdir -p "$ST"
for d in include lib; do
  [ -d "$INSTALL/$d" ] && cp -R "$INSTALL/$d" "$ST/"
done

# MLX delegate ships compiled Metal kernels as a sidecar mlx.metallib that the runtime
# loads at execute() time; the install tree may leave it in the build dir, so make sure a
# copy sits next to the libs. (No-op when MLX wasn't built.)
if [ "${EXECUTORCH_BUILD_MLX:-}" = "ON" ]; then
  found=""
  for mlib in "$INSTALL"/lib/*.metallib "$BUILD"/**/*.metallib "$BUILD"/*.metallib; do
    [ -e "$mlib" ] || continue
    cp -f "$mlib" "$ST/lib/"; found=1
  done
  [ -n "$found" ] || echo "WARN: MLX enabled but no .metallib found to bundle (verify at runtime)"
fi

echo "built + staged -> $ST"
( cd "$ST" && find . -maxdepth 3 -type d | sort | sed 's/^/  /' )
