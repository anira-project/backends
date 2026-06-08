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

[ -d "$STAGING/include" ] || { echo "ERROR: $STAGING/include missing"; exit 1; }
[ -d "$STAGING/lib" ]     || { echo "ERROR: $STAGING/lib missing"; exit 1; }

( cd "$STAGING" && cmake -E tar cf "$OUT_ABS" --format=zip include lib )
echo "Packaged $OUT_ABS"
cmake -E tar tf "$OUT_ABS" | sed 's/^/  /'
