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

ST="$1"; SRC="$2"; MODEL="$3"; KIND="$4"; ARCH="$5"; RUN="${6:-1}"; CONFIG="${7:-Release}"
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
    # Linking the STATIC lib (built /MD, see CMakeLists). Consumers need the same:
    #  - /DTFL_STATIC_LIBRARY_BUILD: header drops __declspec(dllimport) (else __imp_TfLite*)
    #  - CRT must match the lib: /MD (release) / /MDd (debug). cl's CLI default is /MT,
    #    so set it explicitly or you get LNK2038 (RuntimeLibrary mismatch).
    #  - advapi32.lib: cpuinfo's RegGetValueW; ucrt[d].lib: the matching CRT.
    DEFS=""; EXTRA=""; CRT=""
    if [ "$KIND" = "static" ]; then
      DEFS="/DTFL_STATIC_LIBRARY_BUILD"
      if [ "$CONFIG" = "Debug" ]; then CRT="/MDd"; EXTRA="ucrtd.lib advapi32.lib"
      else CRT="/MD"; EXTRA="ucrt.lib advapi32.lib"; fi
    fi
    # MSYS_NO_PATHCONV stops git-bash mangling the /flags into paths.
    MSYS_NO_PATHCONV=1 cl /nologo /std:c++17 /EHsc $CRT $DEFS /I"$INC" "$SRCW" \
      /Fe:smoke.exe /link /LIBPATH:"$LIBDIR" tensorflowlite_c.lib $EXTRA
    if [ "$RUN" = "1" ]; then
      # Windows loads a DLL from the exe's own directory first — copy deps next to
      # smoke.exe rather than relying on PATH (unreliable from git-bash).
      [ "$KIND" = "shared" ] && cp "$ST/lib/tensorflowlite_c.dll" .
      if [ "$CONFIG" = "Debug" ]; then
        # /MDd needs the non-redistributable debug CRT DLLs, which aren't on PATH.
        # Copy them from the VC redist + Windows SDK (paths from the MSVC env).
        a="x64"; [ "$ARCH" = "arm64" ] && a="arm64"
        find "${VCToolsRedistDir:-/c/nonexistent}" -ipath "*debug_nonredist*/$a/*DebugCRT*/*.dll" -exec cp {} . \; 2>/dev/null || true
        ucrtd="$(find "${WindowsSdkDir:-/c/Program Files (x86)/Windows Kits/10}/bin" -name ucrtbased.dll 2>/dev/null | grep "/$a/" | head -1)"
        [ -n "$ucrtd" ] && cp "$ucrtd" .
      fi
      ./smoke.exe "$MODEL"
    else
      echo "compiled+linked OK (run skipped)"
    fi
    ;;

  *) echo "ERROR: unsupported OS: $OS"; exit 1 ;;
esac

echo "smoke OK"
