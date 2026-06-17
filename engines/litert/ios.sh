#!/usr/bin/env bash
# iOS (litert) STATIC: build libLiteRt.a from source via Bazel for device (ios_arm64) +
# simulator (ios_sim_arm64) and combine into a STATIC .xcframework — LiteRT's native C API
# (LiteRt* symbols), CPU-only. Upstream ships only a *dynamic* libLiteRt.dylib for iOS; we build
# static from source so iOS matches the rest of the matrix (static is the preferred iOS linkage —
# no embedded framework to sign, dead-code-stripped into the app/appex). Same transitive-archive
# -merge recipe as the desktop/Android static legs in stage.sh, run once per Apple slice.
# Headers from litert_cc_sdk.zip. Produces dist/<archive>.zip.
#
# NOTE: the exact Bazel iOS flags below are best-effort and may need CI iteration on a macOS
# runner (Apple platform transition + static-xcframework platform metadata are the fiddly bits).
#
# Usage: ios.sh <archive-name>
set -euo pipefail
ARCHIVE="${1:?archive name}"
HERE="$(cd "$(dirname "$0")" && pwd)"
VER="$(tr -d '[:space:]' < "$HERE/VERSION")"

# ---- Headers: SDK litert/c/*.h + synthesized CPU-only build_config.h (same set as other legs) --
sdk="$HERE/litert_cc_sdk"
if [ ! -d "$sdk/litert/c" ]; then
  curl -fsSL "https://github.com/google-ai-edge/LiteRT/releases/download/v${VER}/litert_cc_sdk.zip" -o "$HERE/litert_cc_sdk.zip"
  ( cd "$HERE" && cmake -E tar xf litert_cc_sdk.zip )
fi
hdr="$HERE/ios_include"; rm -rf "$hdr"; mkdir -p "$hdr/litert/build_common"
( cd "$sdk" && find litert/c -name '*.h' | while IFS= read -r h; do mkdir -p "$hdr/$(dirname "$h")"; cp "$h" "$hdr/$h"; done )
cat > "$hdr/litert/build_common/build_config.h" <<'EOF'
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

# ---- Source + host CC toolchain (configure.py), same setup as stage.sh -------------------------
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

# litert_runtime_c_api_so_shim is the cc_library that pulls in the real C API impl closure (the
# same one the .dylib links from). Build it under the iOS Apple platform transition, then merge
# every transitive static archive into one libLiteRt.a — exactly the macOS static recipe, but
# targeting an Apple device/simulator platform instead of macOS.
target=//litert/c:litert_runtime_c_api_so_shim
defines=(--define=litert_disable_gpu=true --define=litert_disable_npu=true)

# Build one Apple slice and merge its transitive static-archive closure into <outdir>/libLiteRt.a.
build_slice() {  # <bazel config: ios_arm64 | ios_sim_arm64> <min-ios> <outdir>
  local bcfg="$1" minos="$2" out="$3"
  rm -rf "$out"; mkdir -p "$out"
  # Use LiteRT's own .bazelrc apple configs: `--config=ios_arm64` / `--config=ios_sim_arm64` expand
  # to --config=ios (apple-toolchain) + --cpu=<slice> + the apple_support iOS platform. The --cpu is
  # the key bit: cpuinfo/XNNPACK/… select() their iOS sources on the legacy --cpu value, so a plain
  # --platforms transition (no --cpu) leaves those configurable attrs unmatched. bulk_test_cpu adds
  # the CPU-only kernel config (same pairing the macOS static leg uses).
  local cfg=(--config="$bcfg" --config=bulk_test_cpu --ios_minimum_os="${minos}")
  ( cd "$SRC" && bazel build "${cfg[@]}" "${defines[@]}" "$target" )
  # Materialise every transitive cc_library archive (the top build leaves them as .o only).
  # cquery --output=label appends the config hash as " (abcdef0)" — keep only the bare label.
  ( cd "$SRC" && bazel cquery "${cfg[@]}" "${defines[@]}" \
      "kind('cc_library rule', deps($target))" --output=label 2>/dev/null ) \
      | awk 'NF{print $1}' | sort -u > "$out/labels.txt"
  ( cd "$SRC" && xargs bazel build "${cfg[@]}" "${defines[@]}" < "$out/labels.txt" )
  cat > "$out/collect.star" <<'STAR'
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
  ( cd "$SRC" && bazel cquery "${cfg[@]}" "${defines[@]}" "$target" \
      --output=starlark --starlark:file="$out/collect.star" ) \
      | grep -v '^$' | sort -u > "$out/all_archives.txt"
  local execroot; execroot="$( cd "$SRC" && bazel info execution_root )"
  # Keep only archives that actually exist on disk (the non-pic candidate paths won't).
  : > "$out/archives.txt"
  while IFS= read -r a; do [ -f "$execroot/$a" ] && printf '%s\n' "$a" >> "$out/archives.txt"; done < "$out/all_archives.txt"
  local count; count="$(wc -l < "$out/archives.txt" | tr -d ' ')"
  [ "$count" -gt 0 ] || { echo "::error::no static archives materialised for iOS $bcfg"; exit 1; }
  # BSD libtool merges the absolute archive paths via -filelist (dodges ARG_MAX, tolerates dup names).
  awk -v r="$execroot" '{print r"/"$0}' "$out/archives.txt" > "$out/filelist.txt"
  libtool -static -no_warning_for_no_symbols -filelist "$out/filelist.txt" -o "$out/libLiteRt.a"
  echo "iOS $bcfg static: merged $count archives -> $(du -h "$out/libLiteRt.a" | cut -f1)"
}

build_slice ios_arm64     13.0 "$HERE/ios-dev"
build_slice ios_sim_arm64 13.0 "$HERE/ios-sim"

# Symbol sanity: the device slice must export the native C API entry point (not a stub).
nm -gU "$HERE/ios-dev/libLiteRt.a" 2>/dev/null | grep -q LiteRtCreateEnvironment \
  || { echo "::error::libLiteRt.a missing LiteRtCreateEnvironment"; exit 1; }

rm -rf LiteRt.xcframework
xcodebuild -create-xcframework \
  -library "$HERE/ios-dev/libLiteRt.a" -headers "$hdr" \
  -library "$HERE/ios-sim/libLiteRt.a" -headers "$hdr" \
  -output LiteRt.xcframework

mkdir -p dist "staging/$ARCHIVE"
cp -R LiteRt.xcframework "staging/$ARCHIVE/"
( cd "staging/$ARCHIVE" && cmake -E tar cf "$OLDPWD/dist/$ARCHIVE.zip" --format=zip LiteRt.xcframework )
echo "packaged dist/$ARCHIVE.zip"
