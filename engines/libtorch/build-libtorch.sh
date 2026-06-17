#!/usr/bin/env bash
# Build a CPU-only SHARED libtorch from source for ONE target, producing the same
# package tree as the upstream prebuilts (include/ lib/ share/cmake/Torch/ [bin/]).
# Used only for the targets PyTorch does NOT ship a 2.12.0 CPU prebuilt for:
#   - macOS x86_64   (PyTorch dropped Intel-mac libtorch after 2.2.2)
#   - Linux aarch64  (no aarch64 libtorch in the download.pytorch.org/cpu index)
#   - Windows arm64  (2.12.0 release not published; only a -debug build exists)
#
# Path: PyTorch's own libtorch builder, tools/build_libtorch.py (BUILD_PYTHON=OFF),
# which installs a complete libtorch tree into <pytorch>/torch/. We restage that.
#
# Usage: build-libtorch.sh <platform> <arch> <staging-dir>
#   <platform>  macos | linux | windows
#   <arch>      x86_64 | aarch64 | arm64
#   <staging>   output prefix; gets include/ lib/ share/ [bin/]
#
# NOTE: this is the from-source recipe; like the ONNXRuntime/TFLite builders it is
# expected to need a few CI rounds to converge per platform. Flags below follow
# PyTorch's official CPU libtorch config.
set -euo pipefail

PLATFORM="${1:?platform}"; ARCH="${2:?arch}"; ST="${3:?staging dir}"
HERE="$(cd "$(dirname "$0")" && pwd)"
VER="$(tr -d '[:space:]' < "$HERE/VERSION")"

# --- Source (recursive: PyTorch vendors its deps as submodules) ----------------
# Windows: PyTorch's repo ships test/ files with names long enough to exceed the
# 260-char MAX_PATH limit, so checkout fails ("Filename too long" -> "unable to
# checkout working tree", exit 128). Enable git's extended-length path support.
# No-op on macOS/Linux.
[ "$PLATFORM" = "windows" ] && git config --global core.longpaths true

SRC="$HERE/pytorch-src"
if [ ! -d "$SRC/.git" ]; then
  git clone --depth 1 --recurse-submodules --shallow-submodules \
    --branch "v${VER}" https://github.com/pytorch/pytorch "$SRC"
fi

python -m pip install --upgrade pip
# Install PyTorch's BUILD requirements only (requirements-build.txt) — NOT the full
# requirements.txt, which drags in dev tools like lintrunner (a Rust/maturin package
# with no win-arm64 wheel; building it from source fails to link via cargo/link.exe).
# None of that is needed to build libtorch.
[ -f "$SRC/requirements-build.txt" ] && python -m pip install -r "$SRC/requirements-build.txt"
python -m pip install pyyaml typing_extensions setuptools numpy

# --- CPU-only base config (shared lib, no python, no tests/CUDA/distributed) ----
# PyTorch vendors an old third_party/protobuf whose CMakeLists has
# cmake_minimum_required(VERSION <3.5); CMake 4.x (pulled in by pip) removed that
# compatibility and errors when building the host protoc ("Could not compile
# universal protoc"). Same class of issue as TFLite's old deps — set the policy
# floor in the env so every nested cmake invocation inherits it.
export CMAKE_POLICY_VERSION_MINIMUM=3.5
export USE_CUDA=0 USE_ROCM=0 USE_CUDNN=0 USE_NCCL=0
export USE_DISTRIBUTED=0 USE_TENSORPIPE=0 USE_GLOO=0 USE_MPI=0
export BUILD_TEST=0 BUILD_PYTHON=0
export BUILD_SHARED_LIBS=1
export USE_FBGEMM=1 USE_QNNPACK=1 USE_PYTORCH_QNNPACK=1
export MAX_JOBS="${MAX_JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)}"

case "$PLATFORM" in
  macos)
    # Native Intel build on a macos-15-intel runner (macos-13 was retired Dec 2025;
    # macos-15-intel is the last x86_64 image, available until ~Fall 2027). PyTorch
    # x86_64-mac is deprecated-but-buildable from source.
    export CMAKE_OSX_ARCHITECTURES="$ARCH"
    export MACOSX_DEPLOYMENT_TARGET=11.0   # >=10.15 → std::filesystem / aligned_alloc OK
    export USE_MKLDNN=1          # oneDNN is fine on x86_64; no system MKL needed
    # BLAS: no override — match PyTorch's macOS default (.ci/pytorch/macos-build.sh sets
    # none), which auto-detects Apple Accelerate (AMX-tuned, full GEMM). Our earlier
    # BLAS=Eigen only routed GEMM through Eigen while still linking Accelerate for LAPACK;
    # the default gives full Accelerate → faster matmul.
    export USE_MPS=0             # no Metal in a CPU libtorch build
    # USE_NATIVE_ARCH=0: don't emit -march=native. The runner's CPU can advertise
    # AVX-512, and Apple Clang rejects PyTorch's `-mavx512fp16` (clang: unknown
    # argument). Building portable dispatch kernels sidesteps it. If a newer AVX-512
    # path still trips Apple Clang at 2.12, set CC/CXX to a brew LLVM clang.
    export USE_NATIVE_ARCH=0
    ;;
  linux)
    # aarch64 native on ubuntu-24.04-arm. No MKL on ARM → OpenBLAS (apt: libopenblas-dev).
    export USE_MKL=0
    export BLAS=OpenBLAS
    export USE_FBGEMM=0          # FBGEMM is x86-only
    # oneDNN's optimized aarch64 GEMM/conv kernels come from the Arm Compute Library (ACL); without
    # it libtorch ships slow reference kernels. Build ACL (pinned to the version PyTorch 2.12 uses,
    # .ci/docker/common/install_acl.sh) with the same scons flags, then enable oneDNN+ACL.
    python -m pip install scons
    ACL_DIR="$HERE/ComputeLibrary"
    if [ ! -e "$ACL_DIR/build/libarm_compute.so" ]; then
      [ -d "$ACL_DIR/.git" ] || git clone https://github.com/ARM-software/ComputeLibrary.git \
        -b v52.6.0 --depth 1 --shallow-submodules "$ACL_DIR"
      ( cd "$ACL_DIR" && scons -j"$MAX_JOBS" Werror=0 debug=0 neon=1 opencl=0 embed_kernels=0 \
          os=linux arch=armv8a build=native multi_isa=1 fixed_format_kernels=1 openmp=1 cppthreads=0 )
    fi
    export ACL_ROOT_DIR="$ACL_DIR"
    export USE_MKLDNN=1 USE_MKLDNN_ACL=1
    ;;
  windows)
    # arm64 native on windows-11-arm with native ARM64 MSVC (cl.exe) — mirroring PyTorch's
    # own win-arm64 CI (.ci/pytorch/windows/arm64/build_libtorch.bat: `vcvarsall.bat arm64`
    # + cl, NOT clang-cl). The arm64 MSVC env is loaded by the workflow (msvc-dev-cmd
    # arch=arm64); we deliberately do NOT set CC/CXX so CMake uses the native arm64 cl.
    # Our earlier clang-cl attempt picked VS's x64-host clang-cl: needed --target hacks,
    # OOM'd under emulation, and selected the aarch64 NEON vec path that breaks on MSVC
    # (the `uint` typedef). Native cl is PyTorch's actual toolchain and avoids all three.
    export USE_MKL=0 USE_MKLDNN=0 USE_FBGEMM=0 USE_QNNPACK=0 USE_PYTORCH_QNNPACK=0
    export USE_DISTRIBUTED=0
    export CMAKE_GENERATOR=Ninja
    export BLAS=Eigen          # self-contained (PyTorch CI uses APL/OpenBLAS for perf)
    # Cap parallelism on the 16 GB runner (native cl is lighter than the emulated clang-cl
    # that OOM'd, but PyTorch's ATen TUs are still big). The 6h budget absorbs it.
    export MAX_JOBS=2
    # Insurance (harmless if native cl selects a different vec path): PyTorch's aarch64 NEON
    # vec headers use the BSD typedefs (uint/ushort/ulong/uchar) absent on MSVC. Inject them
    # into the ATen vec headers that use them (idempotent marker; survives the source cache).
    while IFS= read -r h; do
      grep -q '__win_uint_fix__' "$h" 2>/dev/null && continue
      printf '// __win_uint_fix__\ntypedef unsigned int uint;\ntypedef unsigned short ushort;\ntypedef unsigned long ulong;\ntypedef unsigned char uchar;\n' \
        | cat - "$h" > "$h.__t" && mv "$h.__t" "$h"
    done < <(grep -rlwE 'uint|ushort|ulong|uchar' "$SRC/aten/src/ATen/cpu/vec" 2>/dev/null || true)
    ;;
  *) echo "ERROR: unknown platform '$PLATFORM'"; exit 1 ;;
esac

# A restored/cached build tree pins CMake cache vars (BLAS, USE_*, deployment target…)
# from the PRIOR config — env changes here would otherwise be silently ignored (CMake
# cache vars are sticky). Drop CMakeCache so cmake re-detects against the current env;
# the build objects + sccache keep the rebuild incremental. No-op on a cold build.
rm -f "$SRC/build/CMakeCache.txt"

echo "== building libtorch ${VER} for ${PLATFORM}/${ARCH} (shared, CPU) =="
( cd "$SRC" && python tools/build_libtorch.py )

# build_libtorch.py installs a complete libtorch tree into <pytorch>/torch/.
OUT="$SRC/torch"
[ -f "$OUT/share/cmake/Torch/TorchConfig.cmake" ] || \
  { echo "ERROR: build produced no share/cmake/Torch/TorchConfig.cmake under $OUT"; exit 1; }

mkdir -p "$ST"
for d in include lib share bin; do
  [ -d "$OUT/$d" ] && cp -R "$OUT/$d" "$ST/"
done

echo "built + staged -> $ST"
( cd "$ST" && find . -maxdepth 2 -type d | sort | sed 's/^/  /' )
