#!/usr/bin/env bash
# Merge the bare static `libtensorflowlite_c` plus ALL of its transitive
# dependency archives (tensorflow-lite + xnnpack/ruy/pthreadpool/cpuinfo/
# farmhash/fft2d/flatbuffers/abseil/...) — which CMake leaves scattered under
# the build tree — into ONE self-contained fat archive. This lets anira link a
# single .a/.lib instead of a pile of them.
#
# Order is irrelevant: we're concatenating object files into one archive; symbol
# resolution happens later, when the consumer links.
#
# Usage: bundle-static.sh <build-dir> <output-archive>
#   <build-dir>       the CMake binary dir (holds the built .a/.lib + _deps/)
#   <output-archive>  e.g. staging/<name>/lib/libtensorflowlite_c.a
# Env:
#   BUNDLE_EXCLUDE_REGEX  optional `grep -E` pattern of archive paths to skip
#
# bash 3.2 compatible (macOS /bin/bash) — no mapfile.
set -euo pipefail

BUILD_DIR="${1:?build dir}"
OUT="${2:?output archive}"
EXCLUDE="${BUNDLE_EXCLUDE_REGEX:-}"

OS="$(uname -s)"
case "$OS" in
  Darwin|Linux)          EXT="a"   ;;
  MINGW*|MSYS*|CYGWIN*)  EXT="lib" ;;
  *) echo "ERROR: unsupported OS: $OS"; exit 1 ;;
esac

# Collect candidate archives (dedup identical paths).
ARCHIVES=()
while IFS= read -r f; do
  [ -n "$f" ] && ARCHIVES+=("$f")
done < <(
  find "$BUILD_DIR" -type f -name "*.${EXT}" \
    | { if [ -n "$EXCLUDE" ]; then grep -Ev "$EXCLUDE"; else cat; fi; } \
    | sort -u
)

if [ "${#ARCHIVES[@]}" -eq 0 ]; then
  echo "ERROR: no *.${EXT} archives found under $BUILD_DIR"; exit 1
fi
echo "Merging ${#ARCHIVES[@]} archives -> $OUT"
printf '  %s\n' "${ARCHIVES[@]}"

mkdir -p "$(dirname "$OUT")"
rm -f "$OUT"

case "$OS" in
  Darwin)
    # libtool merges archives directly and tolerates duplicate member names.
    libtool -static -o "$OUT" "${ARCHIVES[@]}"
    ;;

  Linux)
    # Extract every object (one dir per archive to avoid cross-archive object
    # name collisions), then re-archive them all into one indexed library.
    WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
    i=0
    for a in "${ARCHIVES[@]}"; do
      d="$WORK/$i"; mkdir -p "$d"
      ( cd "$d" && ar x "$a" )
      i=$((i + 1))
    done
    # xargs may batch; `ar qcs` appends each batch and (re)builds the index.
    find "$WORK" -name '*.o' -print0 | xargs -0 ar qcs "$OUT"
    ranlib "$OUT" 2>/dev/null || true
    ;;

  MINGW*|MSYS*|CYGWIN*)
    # MSVC lib.exe merges .lib inputs. Needs a Developer Command Prompt env
    # (lib.exe on PATH). Use a response file to dodge command-line length limits.
    command -v lib.exe >/dev/null || { echo "ERROR: lib.exe not on PATH (run in MSVC env)"; exit 1; }
    RSP="$(mktemp)"; trap 'rm -f "$RSP"' EXIT
    printf '/OUT:%s\n' "$(cygpath -w "$OUT")" > "$RSP"
    for a in "${ARCHIVES[@]}"; do
      printf '"%s"\n' "$(cygpath -w "$a")" >> "$RSP"
    done
    lib.exe "@$(cygpath -w "$RSP")"
    ;;
esac

echo "Wrote $OUT"
