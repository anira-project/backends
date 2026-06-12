#!/usr/bin/env bash
# Stage LiteRT's NATIVE C API (libLiteRt — LiteRt* symbols) into <staging> as
# include/litert/c + lib/libLiteRt.{so,dylib,dll}. Distinct from the `tflite` engine (legacy
# TfLite* C API). Headers (both modes) come from the litert_cc_sdk.zip release + a synthesized
# CPU-only build_config.h. Two lib modes:
#   source=prebuilt — fetch the official prebuilt libLiteRt from google-ai-edge/LiteRT's
#                     litert/prebuilt/<platform>/ (Git-LFS, via the media endpoint), pinned to a
#                     main commit (upstream ships these mobile/desktop prebuilts UNVERSIONED).
#   source=build    — build from source via Bazel, CPU-only. Used where no prebuilt exists:
#                     macOS x86_64 (shared), and ALL static legs (upstream ships no static lib —
#                     we build the C API impl and merge its transitive .a closure into libLiteRt.a).
#
# Usage: stage.sh <platform> <arch> <config> <kind> <source> <staging> [url]
set -euo pipefail

PLATFORM="${1:?platform}"; ARCH="${2:?arch}"; CONFIG="${3:-Release}"; KIND="${4:-shared}"
SOURCE="${5:-build}"; ST="${6:?staging dir}"
HERE="$(cd "$(dirname "$0")" && pwd)"
VER="$(tr -d '[:space:]' < "$HERE/VERSION")"
# Pinned LiteRT main commit for the prebuilt libLiteRt binaries (litert/prebuilt/ is unversioned
# upstream). Bump deliberately and re-verify the LiteRt* symbols after.
PREBUILT_SHA="89c838788bba9c2ec6bbefd52971daf39d8e2856"

# ---- Headers (both modes): SDK litert/c/*.h + synthesized CPU-only build_config.h --------------
mkdir -p "$ST/include/litert/build_common" "$ST/lib"
sdk="$HERE/litert_cc_sdk"
if [ ! -d "$sdk/litert/c" ]; then
  curl -fsSL "https://github.com/google-ai-edge/LiteRT/releases/download/v${VER}/litert_cc_sdk.zip" -o "$HERE/litert_cc_sdk.zip"
  ( cd "$HERE" && cmake -E tar xf litert_cc_sdk.zip )   # -> $HERE/litert_cc_sdk/
fi
( cd "$sdk" && find litert/c -name '*.h' | while IFS= read -r h; do
    mkdir -p "$ST/include/$(dirname "$h")"; cp "$h" "$ST/include/$h"; done )
cat > "$ST/include/litert/build_common/build_config.h" <<'EOF'
#ifndef LITERT_BUILD_COMMON_BUILD_CONFIG_H_
#define LITERT_BUILD_COMMON_BUILD_CONFIG_H_
#define LITERT_BUILD_CONFIG_DISABLE_GPU 1
#define LITERT_BUILD_CONFIG_DISABLE_NPU 1
#if LITERT_BUILD_CONFIG_DISABLE_GPU
#define LITERT_DISABLE_GPU
#endif
#if LITERT_BUILD_CONFIG_DISABLE_NPU
#define LITERT_DISABLE_NPU
#endif
#endif  // LITERT_BUILD_COMMON_BUILD_CONFIG_H_
EOF

# ---- source=prebuilt: fetch the official libLiteRt for this platform (LFS via media endpoint) ---
if [ "$SOURCE" = "prebuilt" ]; then
  case "$PLATFORM-$ARCH" in
    windows-x86_64)    sub=windows_x86_64; f=libLiteRt.dll   ;;
    android-arm64-v8a) sub=android_arm64;  f=libLiteRt.so    ;;
    android-x86_64)    sub=android_x86_64; f=libLiteRt.so    ;;
    linux-x86_64)      sub=linux_x86_64;   f=libLiteRt.so    ;;
    linux-aarch64)     sub=linux_arm64;    f=libLiteRt.so    ;;
    macos-arm64)       sub=macos_arm64;    f=libLiteRt.dylib ;;
    *) echo "ERROR: no litert prebuilt for $PLATFORM-$ARCH"; exit 1 ;;
  esac
  curl -fsSL "https://media.githubusercontent.com/media/google-ai-edge/LiteRT/${PREBUILT_SHA}/litert/prebuilt/${sub}/${f}.lfs" -o "$ST/lib/$f"
  if [ "$PLATFORM" = "windows" ]; then
    # The prebuilt ships only the .dll — synthesize the import lib (LiteRt.lib) consumers link.
    m=x64; [ "$ARCH" = "arm64" ] && m=arm64
    ( cd "$ST/lib"
      { echo "LIBRARY libLiteRt.dll"; echo "EXPORTS"
        MSYS_NO_PATHCONV=1 dumpbin /nologo /exports libLiteRt.dll \
          | awk '/^[[:space:]]+[0-9]+[[:space:]]+[0-9A-Fa-f]+[[:space:]]+[0-9A-Fa-f]+[[:space:]]+[A-Za-z_]/{print $4}'
      } > LiteRt.def
      MSYS_NO_PATHCONV=1 lib /nologo /def:LiteRt.def /out:LiteRt.lib /machine:$m )
  fi
  echo "staged litert PREBUILT ($PLATFORM/$ARCH @ ${PREBUILT_SHA:0:7}) -> $ST"
  exit 0
fi

# ---- source=build: Bazel (CPU-only) — for platforms with no prebuilt (macOS x86_64) ------------
SRC="$HERE/litert-src"
if [ ! -d "$SRC/.git" ]; then
  git clone --depth 1 --branch "v${VER}" https://github.com/google-ai-edge/LiteRT "$SRC"
fi
# configure.py generates the host CC toolchain (else "@@local_config_cc//:toolchain ... cpu").
export PYTHON_BIN_PATH="$(python3 -c 'import sys; print(sys.executable)')"
export PYTHON_LIB_PATH="$(python3 -c 'import site; print(site.getsitepackages()[0])')"
export TF_NEED_ROCM=0 TF_NEED_CUDA=0 CC_OPT_FLAGS='-Wno-sign-compare' TF_SET_ANDROID_WORKSPACE=0
# `yes` SIGPIPEs (141) when configure.py closes the pipe; ignore that under pipefail.
( cd "$SRC" && chmod +x configure.py && { set +o pipefail; yes "" | python3 configure.py; } )

case "$PLATFORM" in
  macos) if [ "$ARCH" = "arm64" ]; then cfg=(--config=macos_arm64 --config=bulk_test_cpu)
         else cfg=(--config=bulk_test_cpu --cpu=darwin_x86_64); fi ;;
  linux) cfg=(--config=bulk_test_cpu) ;;
  *) echo "ERROR: no from-source litert recipe for '$PLATFORM' (use a prebuilt leg)"; exit 1 ;;
esac
defines=(--define=litert_disable_gpu=true --define=litert_disable_npu=true)

# ---- source=build, kind=static: no static prebuilt ships upstream, so build it ----------------
# litert_runtime_c_api_so_shim is the cc_library that pulls in LITERT_C_API_COMMON_DEPS (the real
# C API impl) — the same closure the .so/.dylib link from. Strategy: build with --force_pic (so the
# merged archive links into PIE executables and dylibs), then merge every transitive static archive
# into one libLiteRt.a. Building the top cc_library only COMPILES the deps (to .o); each dep's .a is
# materialised on disk only when that library is explicitly requested — so we cquery the transitive
# cc_library labels and `bazel build` them all first, then collect the archives from CcInfo.
if [ "$KIND" = "static" ]; then
  target=//litert/c:litert_runtime_c_api_so_shim
  pic=(--force_pic)
  ( cd "$SRC" && bazel build "${cfg[@]}" "${defines[@]}" "${pic[@]}" "$target" )
  # Materialise every transitive cc_library's archive (the top build leaves them as .o only).
  ( cd "$SRC" && bazel cquery "${cfg[@]}" "${defines[@]}" "${pic[@]}" \
      "kind('cc_library rule', deps($target))" --output=label 2>/dev/null ) \
      | grep -v '^$' > "$HERE/labels.txt"
  ( cd "$SRC" && xargs bazel build "${cfg[@]}" "${defines[@]}" "${pic[@]}" < "$HERE/labels.txt" )
  cat > "$HERE/collect_static_libs.star" <<'STAR'
def format(target):
    ps = providers(target)
    cc = ps.get("CcInfo") if ps else None
    if cc == None:
        return ""
    out = []
    for li in cc.linking_context.linker_inputs.to_list():
        for lib in li.libraries:
            for f in [lib.pic_static_library, lib.static_library]:
                if f != None:
                    out.append(f.path)
    return "\n".join(out)
STAR
  ( cd "$SRC" && bazel cquery "${cfg[@]}" "${defines[@]}" "${pic[@]}" "$target" \
      --output=starlark --starlark:file="$HERE/collect_static_libs.star" ) \
      | grep -v '^$' | sort -u > "$HERE/all_archives.txt"
  execroot="$( cd "$SRC" && bazel info execution_root )"
  # Keep only archives that actually exist (with --force_pic, the non-pic candidate paths won't).
  : > "$HERE/archives.txt"
  while IFS= read -r a; do [ -f "$execroot/$a" ] && printf '%s\n' "$a" >> "$HERE/archives.txt"; done < "$HERE/all_archives.txt"
  count="$(wc -l < "$HERE/archives.txt" | tr -d ' ')"
  [ "$count" -gt 0 ] || { echo "ERROR: no static archives materialised for $target"; exit 1; }
  echo "litert static: merging $count transitive archives -> libLiteRt.a"
  out="$ST/lib/libLiteRt.a"; rm -f "$out"
  if [ "$PLATFORM" = "macos" ]; then
    # BSD libtool: feed the (absolute) archive paths via -filelist to dodge ARG_MAX.
    awk -v r="$execroot" '{print r"/"$0}' "$HERE/archives.txt" > "$HERE/filelist.txt"
    libtool -static -no_warning_for_no_symbols -filelist "$HERE/filelist.txt" -o "$out"
  else
    # GNU ar MRI script: addlib copies every member (dup names across libs are fine), then index.
    { echo "create $out"
      awk -v r="$execroot" '{print "addlib "r"/"$0}' "$HERE/archives.txt"
      echo save; echo end; } | ar -M
    ranlib "$out"
  fi
  echo "staged litert ($PLATFORM/$ARCH/static, from source, $(du -h "$out" | cut -f1)) -> $ST"
  exit 0
fi

# ---- source=build, kind=shared: build libLiteRt.{so,dylib} (macOS x86_64) --------------------
( cd "$SRC" && bazel build "${cfg[@]}" "${defines[@]}" //litert/c:litert_runtime_c_api_shared_lib )
# Locate the built shared lib (bazel-bin is a symlink find -L follows on unix).
lib="$(find -L "$SRC/bazel-bin" -maxdepth 6 \( -name 'libLiteRt.so' -o -name 'libLiteRt.dylib' \) 2>/dev/null | head -1)"
[ -n "$lib" ] || { echo "ERROR: libLiteRt not found under bazel-bin"; exit 1; }
cp -L "$lib" "$ST/lib/"
echo "staged litert ($PLATFORM/$ARCH/$KIND, from source) -> $ST"
