#!/usr/bin/env bash
# iOS (litert) STATIC: build libLiteRt.a from source via Bazel for device (ios_arm64) +
# simulator (ios_sim_arm64) and combine into a STATIC .xcframework — LiteRT's native C API
# (LiteRt* symbols), CPU-only. Upstream ships only a *dynamic* libLiteRt.dylib for iOS; we build
# static from source so iOS matches the rest of the matrix (static is the preferred iOS linkage —
# no embedded framework to sign, dead-code-stripped into the app/appex). Same transitive-archive
# -merge recipe as the desktop/Android static legs in stage.sh, run once per Apple slice.
# Headers + source both from the pinned PREBUILT_SHA (see stage.sh). Produces dist/<archive>.zip.
#
# NOTE: the exact Bazel iOS flags below are best-effort and may need CI iteration on a macOS
# runner (Apple platform transition + static-xcframework platform metadata are the fiddly bits).
#
# Usage: ios.sh <archive-name>
set -euo pipefail
ARCHIVE="${1:?archive name}"
HERE="$(cd "$(dirname "$0")" && pwd)"
VER="$(tr -d '[:space:]' < "$HERE/VERSION")"
# Pinned LiteRT main commit — MUST match stage.sh's PREBUILT_SHA so the iOS static slice ships the
# same model-load ABI (env-leading LiteRtCreateModelFrom*) as every other leg. Keep in sync.
PREBUILT_SHA="89c838788bba9c2ec6bbefd52971daf39d8e2856"

# ---- Headers: litert/c/*.h from $PREBUILT_SHA + synthesized CPU-only build_config.h (same ref as
# the from-source build below, so headers and lib never skew — see stage.sh for the why) ---------
sdk="$HERE/LiteRT-${PREBUILT_SHA}"
if [ ! -d "$sdk/litert/c" ]; then
  curl -fsSL "https://github.com/google-ai-edge/LiteRT/archive/${PREBUILT_SHA}.tar.gz" -o "$HERE/litert-src.tar.gz"
  ( cd "$HERE" && cmake -E tar xzf litert-src.tar.gz )
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
  git init -q "$SRC"
  git -C "$SRC" remote add origin https://github.com/google-ai-edge/LiteRT
  git -C "$SRC" fetch -q --depth 1 origin "$PREBUILT_SHA"
  git -C "$SRC" checkout -q --detach FETCH_HEAD
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
build_slice() {  # <cpu: ios_arm64|ios_sim_arm64> <apple-support platform> <min-ios> <outdir>
  local cpuv="$1" platv="$2" minos="$3" out="$4"
  rm -rf "$out"; mkdir -p "$out"
  # Replicate LiteRT's build:ios_arm64 / build:ios_sim_arm64 — apple-toolchain + --cpu=<slice> + the
  # apple_support iOS platform — but WITHOUT the `--copt=-fembed-bitcode` that build:ios injects. The
  # --cpu is essential: cpuinfo/XNNPACK/… select() their iOS sources on the legacy --cpu value, so a
  # bare --platforms transition leaves those configurable attrs unmatched. Bitcode is dropped because
  # Xcode 16 removed it: the embedded bitcode bloats the archive (~44M vs ~15M) and hides the Mach-O
  # symbols from nm. bulk_test_cpu adds the CPU-only kernel config (same pairing the macOS leg uses).
  local cfg=(--config=apple-toolchain
             --apple_platform_type=ios
             --cpu="$cpuv"
             --platforms="@build_bazel_apple_support//platforms:${platv}"
             --copt=-Wno-c++11-narrowing
             --ios_minimum_os="${minos}"
             --config=bulk_test_cpu)
  ( cd "$SRC" && bazel build "${cfg[@]}" "${defines[@]}" "$target" )
  # Materialise every transitive library archive (the top build leaves them as .o only).
  # MUST include objc_library, not just cc_library: on Apple, tflite::profiling::platform_profiler
  # references MaybeCreateSignpostProfiler(), which is DEFINED in signpost_profiler.mm — an
  # objc_library (.mm/os_signpost). A `kind('cc_library rule', ...)` filter skips it, so its archive
  # is named in the linking closure below (collect.star) but never built; the "keep only files that
  # exist" filter then silently drops it, shipping a libLiteRt.a with a dangling signpost reference
  # that fails to link into any iOS app. Match cc_library + objc_library so .mm TUs are merged too.
  # cquery --output=label appends the config hash as " (abcdef0)" — keep only the bare label.
  ( cd "$SRC" && bazel cquery "${cfg[@]}" "${defines[@]}" \
      "kind('(cc_library|objc_library) rule', deps($target))" --output=label 2>/dev/null ) \
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
  # Keep only archives that actually exist on disk (the non-pic candidate paths won't). LOG anything
  # dropped: a candidate that's in the linking closure but absent on disk is usually a transitive
  # library whose rule kind we didn't materialise above (the signpost_profiler.mm class of miss) —
  # surface it rather than silently shrinking the merge set. The self-contained gate below is the
  # hard backstop; this is the breadcrumb that says which TU went missing.
  : > "$out/archives.txt"
  while IFS= read -r a; do
    if [ -f "$execroot/$a" ]; then printf '%s\n' "$a" >> "$out/archives.txt"
    else echo "::warning::iOS $cpuv: closure archive not built, dropping from merge: $a"; fi
  done < "$out/all_archives.txt"
  local count; count="$(wc -l < "$out/archives.txt" | tr -d ' ')"
  [ "$count" -gt 0 ] || { echo "::error::no static archives materialised for iOS $cpuv"; exit 1; }
  # BSD libtool merges the absolute archive paths via -filelist (dodges ARG_MAX, tolerates dup names).
  awk -v r="$execroot" '{print r"/"$0}' "$out/archives.txt" > "$out/filelist.txt"
  libtool -static -no_warning_for_no_symbols -filelist "$out/filelist.txt" -o "$out/libLiteRt.a"
  echo "iOS $cpuv static: merged $count archives -> $(du -h "$out/libLiteRt.a" | cut -f1)"
}

# Self-contained gate: a static .a is lazily linked — the consumer pulls only the objects it
# references, so a dangling reference inside an object that anira DOES pull (tflite::profiling::
# platform_profiler -> the os_signpost path) is invisible to a presence check (nm -gjU hides
# undefined symbols by design) and to a smoke that never exercises that path — it only blows up when
# the real app links. Scan instead for undefined symbols in the library's OWN namespaces (tflite/
# litert/absl/tsl) that nothing in the merged archive defines: each is a packaging gap — a TU that
# was referenced but never compiled/merged (exactly the signpost_profiler.mm miss this fixed).
# External/system undefineds (libc, libc++, Obj-C runtime, Foundation/Accelerate/Metal) are expected
# and ignored. This is the hard backstop for the merge above: if a future rule-kind/closure change
# drops an internal TU again, the build fails here instead of shipping an unlinkable xcframework.
check_self_contained() {  # <libLiteRt.a> <slice-name>
  local a="$1" name="$2"
  # Defined external symbols (nm -gjU: global, just-names, no undefined) — strip the path: prefix.
  nm -gjUo "$a" 2>/dev/null | awk -F: '{print $NF}' | awk '{print $1}' | sort -u > "$HERE/.def.txt"
  # Undefined references across all objects (-o prefixes path; "U" is the type, name is the 3rd col).
  nm -o "$a" 2>/dev/null | awk '$2=="U"{print $3}' | sort -u > "$HERE/.und.txt"
  local missing
  missing="$(comm -23 "$HERE/.und.txt" "$HERE/.def.txt" | grep -E '_ZN6tflite|_ZN6litert|_ZN4absl|_ZN3tsl' || true)"
  rm -f "$HERE/.def.txt" "$HERE/.und.txt"
  if [ -n "$missing" ]; then
    echo "::error::$name: merged libLiteRt.a has internal undefined symbols with no in-archive definition (unlinkable):"
    printf '%s\n' "$missing" | c++filt
    return 1
  fi
  echo "$name: self-contained (no dangling internal symbols)"
}

build_slice ios_arm64     ios_arm64     13.0 "$HERE/ios-dev"
build_slice ios_sim_arm64 ios_sim_arm64 13.0 "$HERE/ios-sim"

# Symbol sanity: the device slice must export the native C API entry point (not a stub). Apple nm
# prefixes a leading underscore (_LiteRtCreateEnvironment) and may emit per-object warnings — don't
# mask them, and log the symbol count so a miss is debuggable rather than silent.
syms="$(nm -gjU "$HERE/ios-dev/libLiteRt.a" 2>/dev/null || true)"
total="$(printf '%s\n' "$syms" | grep -c . || true)"
hit="$(printf '%s\n' "$syms" | grep -c 'LiteRtCreateEnvironment' || true)"
echo "device slice: $total global defined syms; LiteRtCreateEnvironment matches=$hit"
[ "$hit" -gt 0 ] || { echo "::error::libLiteRt.a missing LiteRtCreateEnvironment (total syms=$total)"; exit 1; }

# Both slices must be fully self-contained, or the xcframework won't link into an iOS target.
check_self_contained "$HERE/ios-dev/libLiteRt.a" "device slice"   || exit 1
check_self_contained "$HERE/ios-sim/libLiteRt.a" "simulator slice" || exit 1

rm -rf LiteRt.xcframework
xcodebuild -create-xcframework \
  -library "$HERE/ios-dev/libLiteRt.a" -headers "$hdr" \
  -library "$HERE/ios-sim/libLiteRt.a" -headers "$hdr" \
  -output LiteRt.xcframework

mkdir -p dist "staging/$ARCHIVE"
cp -R LiteRt.xcframework "staging/$ARCHIVE/"
( cd "staging/$ARCHIVE" && cmake -E tar cf "$OLDPWD/dist/$ARCHIVE.zip" --format=zip LiteRt.xcframework )
echo "packaged dist/$ARCHIVE.zip"
