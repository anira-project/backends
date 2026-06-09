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
# NOTE: this is the from-source recipe; like the ONNXRuntime/LiteRT builders it is
# expected to need a few CI rounds to converge per platform (see ../../TODO.md for
# how those settled). Flags below follow PyTorch's official CPU libtorch config.
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
# universal protoc"). Same class of issue as LiteRT's old deps — set the policy
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
    export BLAS=Eigen            # avoid a system-Accelerate/MKL dependency in the lib
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
    # oneDNN on aarch64 wants the Arm Compute Library; keep it off for the first
    # self-contained pass (reference kernels). Revisit for perf once green.
    export USE_MKLDNN=0
    export USE_FBGEMM=0          # FBGEMM is x86-only
    ;;
  windows)
    # arm64 native on windows-11-arm. Build with clang-cl, NOT MSVC cl: PyTorch's
    # official win-arm64 binaries are built with LLVM/clang-cl (.ci/pytorch/windows/
    # arm64), and MSVC cl trips on PyTorch's ARM64 NEON intrinsics (sleef / ATen vec).
    # clang-cl targets the MSVC ABI, so the resulting torch.dll + import lib stay
    # drop-in for an MSVC-built anira consumer. The MSVC dev env (loaded by the
    # workflow) still supplies headers/libs/linker; CC/CXX only swap the compiler.
    export USE_MKL=0 USE_MKLDNN=0 USE_FBGEMM=0 USE_QNNPACK=0 USE_PYTORCH_QNNPACK=0
    export USE_DISTRIBUTED=0
    export CMAKE_GENERATOR=Ninja
    export CC=clang-cl CXX=clang-cl
    command -v clang-cl >/dev/null || { echo "ERROR: clang-cl not on PATH (install LLVM)"; exit 1; }
    # The clang-cl on PATH is VS's x64-host build, which defaults to an x64 TARGET —
    # it then links the arm64 MSVC runtime and fails: "msvcrtd.lib(...): machine type
    # arm64 conflicts with x64". clang-cl is a cross-compiler, so force the arm64
    # triple; the arm64 Windows SDK/runtime from the MSVC env supplies the libs. CMake
    # seeds CMAKE_{C,CXX}_FLAGS from these, so the compiler check + whole build inherit it.
    export CFLAGS="--target=arm64-pc-windows-msvc${CFLAGS:+ $CFLAGS}"
    export CXXFLAGS="--target=arm64-pc-windows-msvc${CXXFLAGS:+ $CXXFLAGS}"
    ;;
  *) echo "ERROR: unknown platform '$PLATFORM'"; exit 1 ;;
esac

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
