#!/usr/bin/env bash
# Compile (and, when the binary is native, run) a smoke test against a PACKAGED
# artifact (staging include/ + lib/). Linking the static lib here is the real
# proof the bundled archive is symbol-complete.
#
# Usage: smoke-test.sh <staging-dir> <smoke-src> <model> <kind> <arch> <run:0|1>
#   <kind>  shared | static
#   <arch>  target arch (x86_64|arm64|aarch64) — used for macOS cross (-arch)
#   <run>   1 = also execute (native target), 0 = compile+link only
set -euo pipefail

ST="$1"; SRC="$2"; MODEL="$3"; KIND="$4"; ARCH="$5"; RUN="${6:-1}"
OS="$(uname -s)"

case "$OS" in
  Darwin|Linux)
    BIN="$(mktemp -d)/smoke"
    CXX="${CXX:-c++}"
    FLAGS=(-std=c++17 -I "$ST/include")
    [ "$OS" = "Darwin" ] && FLAGS+=(-arch "$ARCH")
    if [ "$KIND" = "static" ]; then
      LINK=("$ST/lib/libtensorflowlite_c.a" -lpthread -lm)
      [ "$OS" = "Linux" ] && LINK+=(-ldl)
    else
      LINK=(-L "$ST/lib" -ltensorflowlite_c)
    fi
    echo "+ $CXX ${FLAGS[*]} <src> ${LINK[*]}"
    "$CXX" "${FLAGS[@]}" "$SRC" "${LINK[@]}" -o "$BIN"
    if [ "$RUN" = "1" ]; then
      if [ "$OS" = "Darwin" ]; then export DYLD_LIBRARY_PATH="$ST/lib"; else export LD_LIBRARY_PATH="$ST/lib"; fi
      "$BIN" "$MODEL"
    else
      echo "compiled+linked OK (run skipped for $ARCH)"
    fi
    ;;

  MINGW*|MSYS*|CYGWIN*)
    command -v cl >/dev/null || { echo "ERROR: cl.exe not on PATH (need MSVC env)"; exit 1; }
    INC="$(cygpath -w "$ST/include")"; LIBDIR="$(cygpath -w "$ST/lib")"; SRCW="$(cygpath -w "$SRC")"
    # MSYS_NO_PATHCONV stops git-bash mangling the /flags into paths.
    MSYS_NO_PATHCONV=1 cl /nologo /std:c++17 /EHsc /I"$INC" "$SRCW" \
      /Fe:smoke.exe /link /LIBPATH:"$LIBDIR" tensorflowlite_c.lib
    if [ "$RUN" = "1" ]; then
      # Windows loads a DLL from the exe's own directory first — copy it next to
      # smoke.exe rather than relying on PATH (which is unreliable from git-bash).
      [ "$KIND" = "shared" ] && cp "$ST/lib/tensorflowlite_c.dll" .
      ./smoke.exe "$MODEL"
    else
      echo "compiled+linked OK (run skipped)"
    fi
    ;;

  *) echo "ERROR: unsupported OS: $OS"; exit 1 ;;
esac

echo "smoke OK"
