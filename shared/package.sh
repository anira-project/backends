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
# overrides with PACKAGE_DIRS="include lib share bin" — it ships a full CMake package
# tree consumed via find_package(Torch), so share/ must be preserved.
#
# include and lib are REQUIRED (a missing one means a broken stage -> hard error). share
# and bin are OPTIONAL: packaged when present, skipped otherwise (bin/ only exists on some
# Windows libtorch builds), so a single fixed PACKAGE_DIRS works for every leg.
DIRS="${PACKAGE_DIRS:-include lib}"
PACK=""
for d in $DIRS; do
  if [ -d "$STAGING/$d" ]; then
    PACK="$PACK $d"
  elif [ "$d" = "share" ] || [ "$d" = "bin" ]; then
    echo "note: optional $STAGING/$d not present — skipping"
  else
    echo "ERROR: required $STAGING/$d missing"; exit 1
  fi
done

( cd "$STAGING" && cmake -E tar cf "$OUT_ABS" --format=zip $PACK )
echo "Packaged $OUT_ABS"
cmake -E tar tf "$OUT_ABS" | sed 's/^/  /'
