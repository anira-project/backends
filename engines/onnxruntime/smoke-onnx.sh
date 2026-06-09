#!/usr/bin/env bash
# Compile + (optionally) run the onnxruntime smoke against a packaged STATIC lib.
# Linking proves the bundled lib is symbol-complete; running exercises OrtEnv init.
#
# Usage: smoke-onnx.sh <staging-dir> <smoke-src> <arch> <config> <run:0|1>
#   <arch>    x86_64|arm64|aarch64 (macOS uses it for -arch cross)
#   <config>  Release|Debug        (Windows CRT match)
#   <run>     1 = also execute (native), 0 = compile+link only
set -euo pipefail

# NB: the staging lib dir is LIBDIR, NOT LIB — on Windows `LIB` is the MSVC linker's
# search-path env var; clobbering it makes cl fail to find advapi32.lib (LNK1181).
ST="$1"; SRC="$2"; ARCH="${3:-}"; CONFIG="${4:-Release}"; RUN="${5:-1}"
INC="$ST/include"; LIBDIR="$ST/lib"
OS="$(uname -s)"

run_or_note() { if [ "$RUN" = "1" ]; then "$@"; else echo "compiled+linked OK (run skipped)"; fi; }

case "$OS" in
  Darwin)
    BIN="$(mktemp -d)/smoke"; CXX="${CXX:-c++}"
    F=(-std=c++17 -I "$INC"); [ "$ARCH" = "x86_64" ] && F+=(-arch x86_64)
    # onnxruntime's platform code pulls in CoreFoundation/Foundation (timezone, logging).
    "$CXX" "${F[@]}" "$SRC" "$LIBDIR/libonnxruntime.a" \
      -framework Foundation -framework CoreFoundation -o "$BIN"
    run_or_note "$BIN"
    ;;
  Linux)
    BIN="$(mktemp -d)/smoke"; CXX="${CXX:-c++}"
    "$CXX" -std=c++17 -I "$INC" "$SRC" "$LIBDIR/libonnxruntime.a" -lpthread -ldl -lm -lrt -o "$BIN"
    run_or_note "$BIN"
    ;;
  MINGW*|MSYS*|CYGWIN*)
    command -v cl >/dev/null || { echo "ERROR: cl.exe not on PATH (MSVC env)"; exit 1; }
    # CRT must match the lib (/MD|/MDd, cl's CLI default is /MT). advapi32: cpuinfo's
    # RegGetValueW; ucrt[d]: the matching CRT. (NB: do not touch the LIB env var — see top.)
    if [ "$CONFIG" = "Debug" ]; then CRT="/MDd"; EXTRA="ucrtd.lib advapi32.lib"
    else CRT="/MD"; EXTRA="ucrt.lib advapi32.lib"; fi
    MSYS_NO_PATHCONV=1 cl /nologo /std:c++17 /EHsc "$CRT" /I"$(cygpath -w "$INC")" "$(cygpath -w "$SRC")" \
      /Fe:smoke.exe /link /LIBPATH:"$(cygpath -w "$LIBDIR")" onnxruntime.lib $EXTRA
    if [ "$RUN" = "1" ]; then
      if [ "$CONFIG" = "Debug" ]; then
        # /MDd needs the non-redistributable debug CRT DLLs (ucrtbased/vcruntime140d/
        # msvcp140d), which aren't on PATH. Copy them next to smoke.exe from the VC
        # redist + Windows SDK (paths come from the MSVC env). Else smoke.exe won't start.
        a="x64"; [ "$ARCH" = "arm64" ] && a="arm64"
        find "${VCToolsRedistDir:-/c/nonexistent}" -ipath "*debug_nonredist*/$a/*DebugCRT*/*.dll" -exec cp {} . \; 2>/dev/null || true
        ucrtd="$(find "${WindowsSdkDir:-/c/Program Files (x86)/Windows Kits/10}/bin" -name ucrtbased.dll 2>/dev/null | grep "/$a/" | head -1)"
        [ -n "$ucrtd" ] && cp "$ucrtd" .
      fi
      ./smoke.exe
    else
      echo "compiled+linked OK (run skipped)"
    fi
    ;;
  *) echo "ERROR: unsupported OS $OS"; exit 1 ;;
esac
echo "onnx smoke OK"
