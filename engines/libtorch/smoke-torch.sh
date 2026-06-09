#!/usr/bin/env bash
# Build + (optionally) run the libtorch smoke against a PACKAGED staging tree, via
# find_package(Torch) — the same consumption path anira uses. Configuring/linking
# proves the (re)packaged tree is complete; running proves the libs load + compute.
#
# Usage: smoke-torch.sh <staging-dir> <test-src-dir> <run:0|1>
#   <staging-dir>   prefix containing include/ lib/ share/cmake/Torch/
#   <test-src-dir>  dir with smoke.cpp + CMakeLists.txt (engines/libtorch/test)
#   <run>           1 = also execute (native target), 0 = configure+build only
set -euo pipefail

ST="${1:?staging dir}"; SRCDIR="${2:?test src dir}"; RUN="${3:-1}"
OS="$(uname -s)"

# Absolute paths (CMake + cross-shell friendly).
ST_ABS="$(cd "$ST" && pwd)"
SRC_ABS="$(cd "$SRCDIR" && pwd)"
BUILD="$(mktemp -d)/smoke-build"

cmake -S "$SRC_ABS" -B "$BUILD" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_PREFIX_PATH="$ST_ABS"
cmake --build "$BUILD" --config Release -j

if [ "$RUN" != "1" ]; then
  echo "configured + built OK (run skipped)"; echo "smoke OK"; exit 0
fi

# Locate the built binary (multi-config generators nest it under Release/).
bin="$BUILD/smoke"; [ -f "$bin" ] || bin="$BUILD/Release/smoke.exe"; [ -f "$bin" ] || bin="$BUILD/smoke.exe"
[ -f "$bin" ] || { echo "ERROR: smoke binary not found under $BUILD"; exit 1; }

# Make the shared libtorch libs loadable at runtime.
case "$OS" in
  Darwin) export DYLD_LIBRARY_PATH="$ST_ABS/lib${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}" ;;
  Linux)  export LD_LIBRARY_PATH="$ST_ABS/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" ;;
  MINGW*|MSYS*|CYGWIN*) export PATH="$ST_ABS/lib:$PATH" ;;  # Windows loads DLLs from PATH/cwd
esac

"$bin"
echo "smoke OK"
