#!/usr/bin/env bash
# Assemble an install tree (include/ + lib/) into a zip named the way anira expects.
# Cross-platform via `cmake -E tar` (works on macOS/Linux/Windows runners).
#
# Usage: package.sh <staging-dir> <archive-basename> [out-dir]
#   <staging-dir>       a CMake install prefix containing include/ and lib/
#   <archive-basename>  e.g. tensorflowlite_c-2.17.0-macOS-arm64-static
#   [out-dir]           defaults to ./dist
set -euo pipefail

STAGING="$1"
NAME="$2"
OUT="${3:-dist}"

mkdir -p "$OUT"
OUT_ABS="$(cd "$OUT" && pwd)/${NAME}.zip"

# Dirs to archive. Defaults to include + lib (LiteRT/ONNXRuntime layout). libtorch
# overrides with PACKAGE_DIRS="include lib share [bin]" — it ships a full CMake
# package tree consumed via find_package(Torch), so share/ must be preserved.
DIRS="${PACKAGE_DIRS:-include lib}"
for d in $DIRS; do
  [ -d "$STAGING/$d" ] || { echo "ERROR: $STAGING/$d missing"; exit 1; }
done

( cd "$STAGING" && cmake -E tar cf "$OUT_ABS" --format=zip $DIRS )
echo "Packaged $OUT_ABS"
cmake -E tar tf "$OUT_ABS" | sed 's/^/  /'
