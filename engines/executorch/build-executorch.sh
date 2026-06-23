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
       python tools/build_libtorch.py )
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
    # MLX (backends/mlx/CMakeLists.txt) hard-requires a >=14.0 deployment target; CoreML
    # and the CPU path are fine at 12.0. So arm64 (MLX built in) floors at 14.0 and Intel
    # (no MLX) stays at 12.0. NOTE: the arm64 package therefore requires macOS 14+.
    if [ "$ARCH" = "arm64" ]; then MACVER=14.0; else MACVER=12.0; fi
    export MACOSX_DEPLOYMENT_TARGET="$MACVER"
    ET_FLAGS+=(
      -DCMAKE_OSX_ARCHITECTURES="$ARCH"
      -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACVER"
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
    # Kernel ops use the idiom `constexpr auto name = "...";` at block scope. MSVC rejects a
    # block-scope constexpr pointer bound to a string literal's address (C2131: expression did
    # not evaluate to a constant). `name` is only used as a runtime error string by the
    # ET_SWITCH macros, so a plain const pointer is equivalent. Patch tree-wide. Idempotent.
    grep -rlZ 'constexpr auto name =' "$SRC" 2>/dev/null \
      | xargs -0 --no-run-if-empty sed -i 's|constexpr auto name =|const char* const name =|g'
    ;;
  *) echo "ERROR: unknown platform '$PLATFORM'"; exit 1 ;;
esac

# A restored/cached build tree pins CMake cache vars from the PRIOR config; drop the cache
# so cmake re-detects against the current flags (objects + any compiler cache keep the
# rebuild incremental). No-op on a cold build. Mirrors build-libtorch.sh.
rm -f "$BUILD/CMakeCache.txt"

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

echo "== building ExecuTorch ${VER} for ${PLATFORM}/${ARCH} (static, CPU + XNNPACK${EXECUTORCH_BUILD_MLX:+ +MLX}); -j ${BUILD_JOBS} (cores=${ncores} mem=${memgb}GB) =="
cmake -S "$SRC" -B "$BUILD" "${ET_FLAGS[@]}"
cmake --build "$BUILD" -j "$BUILD_JOBS" --target install

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
