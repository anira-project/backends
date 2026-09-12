#!/usr/bin/env bash
# Merge a built ExecuTorch tree into ONE self-contained static archive that links
# ON-DEMAND like every other anira backend archive — no -force_load / --whole-archive /
# /WHOLEARCHIVE on the consumer side, no CMake package.
#
# Why this needs more than scripts/bundle-static.sh: ExecuTorch registers its operator
# kernels and delegate backends from static initializers (register_kernels(...) /
# register_backend(...) in a handful of TUs). Nothing references those TUs, so an on-demand
# archive link drops them and every `.pte` fails at load with "operator not found" / no
# backend — which is exactly why upstream bakes force-load into its exported targets. A
# naive libtool/ar merge keeps per-object granularity and inherits that problem.
#
# Fix: partial-link (`ld -r`) the registration archives TOGETHER WITH the core runtime
# (executorch_core: runtime_init, Program, Method, the kernel/backend registry) into ONE
# relocatable object, `executorch_registrations.o`, and put that object into the merged
# archive next to the on-demand members. An archive member is an all-or-nothing unit: any
# consumer of the runtime references executorch_core, so the whole member is pulled in,
# static initializers included. (Without the core in the blob nothing references it and
# the linker skips it — the archive links fine and every model fails at execute.)
# Consumers then link the archive exactly like libonnxruntime.a.
#
# Windows has no partial link (neither link.exe nor lld-link has -r). Whole-archiving the
# entire merged lib is not an option either: XNNPACK's per-ISA config tables reference
# microkernels that are not built for every target (e.g. the f16 neonfp16arith set), which
# only on-demand resolution tolerates. So Windows ships the blob set as a SECOND, small
# lib — executorch_registrations.lib — that the consumer links with /WHOLEARCHIVE next to
# the on-demand executorch.lib (see the anira CMake).
#
# Registration set (what upstream force-loads, restricted to what we build and what a
# generic CPU runtime may register ONCE):
#   executorch                    primitive ops + runtime (upstream force-loads it)
#   optimized_native_cpu_ops_lib  full aten op set: optimized kernels + portable fallback
#   quantized_ops_lib             quantized ops (disjoint namespace)
#   xnnpack_backend               XNNPACK delegate registration
# plus xnnpack-microkernels-prod (WHOLE_LIBS): not a registration, but its dispatch tables
# reference microkernels from data sections that on-demand resolution cannot satisfy on ld64.
# Deliberately EXCLUDED from the archive: portable_ops_lib / optimized_ops_lib /
# optimized_portable_ops_lib re-register the same aten ops (the registry aborts on the
# duplicate at static-init), and the hardware delegates (CoreML/MPS/MLX/Metal/Vulkan) unless
# a -gpu variant asks for them through MERGE_DELEGATES (below) — GPU is always a separate
# archive, so the default package never carries a delegate registration.
#
# The exported ExecuTorchTargets.cmake is cross-checked: every library upstream marks for
# force-load must be either in REG_LIBS or in EXCLUDE_LIBS, so an upstream bump that adds a
# new registering library fails loudly here instead of silently shipping an archive whose
# new kernels never register.
#
# Usage: merge-static.sh <platform> <install-prefix> <output-archive>
#   <platform>        macos | ios | linux | android | windows
#   <install-prefix>  ExecuTorch `cmake --install` prefix. Its lib/cmake/ExecuTorch/
#                     ExecuTorchTargets.cmake is the source of truth for BOTH the member
#                     list (every static IMPORTED_LOCATION it exports — resolved against the
#                     prefix, or the absolute build-tree path ExecuTorch 1.3.1 bakes in for
#                     the few targets it installs into the wrong place) AND the force-load
#                     cross-check.
#   <output-archive>  e.g. <staging>/lib/libexecutorch.a  (windows: executorch.lib, plus
#                     executorch_registrations.lib written next to it)
# Env:
#   MERGE_LD   linker for the partial link (default: `ld` — ld64 on Apple, GNU ld / ld.lld
#              on Linux; Android resolves the NDK's ld.lld from ANDROID_NDK_HOME).
#   MERGE_DELEGATES        -gpu variants: space-separated delegate registration libs to
#                          INCLUDE (coremldelegate mpsdelegate mlxdelegate vulkan_backend).
#                          Each is a static-initializer register_backend() TU that upstream
#                          force-loads, so it joins the pre-linked blob; its dependency libs
#                          leave EXCLUDE_LIBS (force-loaded ones join the blob, the rest
#                          become ordinary on-demand members).
#   MERGE_EXTRA_ARCHIVES   extra on-demand archives that are installed but NOT exported
#                          (libmlx.a: MLX's CMake installs it without an EXPORT, and
#                          executorch-config.cmake find_library()s it at consume time).
#
# bash 3.2 compatible (macOS /bin/bash).
set -euo pipefail

PLATFORM="${1:?platform}"; PREFIX="${2:?install prefix}"; OUT="${3:?output archive}"

REG_LIBS="executorch optimized_native_cpu_ops_lib quantized_ops_lib xnnpack_backend"
# Also pre-linked whole, for a different reason: XNNPACK's runtime-dispatch config tables
# reference its microkernel symbols from DATA sections, which on-demand archive resolution
# does not satisfy (Apple's linker fails with "does not have address" fixup errors on
# members it never materialized). The microkernel archive is a leaf with no dependencies
# and no colliding symbols, so it simply joins the blob.
WHOLE_LIBS="xnnpack-microkernels-prod"
# The runtime core joins the blob so that using the runtime at all pulls the blob in.
CORE_LIBS="executorch_core"
EXCLUDE_LIBS="portable_ops_lib optimized_ops_lib optimized_portable_ops_lib \
  coremldelegate coreml_util coreml_inmemoryfs mpsdelegate mlxdelegate mlx metal_backend \
  vulkan_backend vulkan_schema protobuf-lite libprotobuf-lite"
# Hardware delegates (-gpu variants only, see MERGE_DELEGATES above): the registering libs
# and the dependency libs that ride with them. Names as exported by ExecuTorch 1.3.1
# (backends/apple/{coreml,mps}, backends/mlx, backends/vulkan).
DELEGATE_REG_LIBS="coremldelegate mpsdelegate mlxdelegate vulkan_backend"
DELEGATE_DEP_LIBS="coreml_util coreml_inmemoryfs protobuf-lite libprotobuf-lite mlx metal_backend vulkan_schema"

PREFIX="$(cd "$PREFIX" && pwd)"
TARGETS="$PREFIX/lib/cmake/ExecuTorch/ExecuTorchTargets.cmake"
[ -f "$TARGETS" ] || { echo "ERROR: $TARGETS not found — install the ExecuTorch CMake package first"; exit 1; }
mkdir -p "$(dirname "$OUT")"
OUT="$(cd "$(dirname "$OUT")" && pwd)/$(basename "$OUT")"
WORK="$(dirname "$OUT")/.merge-$(basename "$OUT")"
rm -rf "$WORK"; mkdir -p "$WORK"

in_list() { case " $2 " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

# --- Cross-check the exported force-load set against ours -------------------------------
# Upstream's per-platform force-load option (tools/cmake/Utils.cmake) names the target via
# a generator expression that survives export verbatim:
#   -force_load,$<TARGET_FILE:X>  |  --whole-archive $<TARGET_FILE:X>  |  /WHOLEARCHIVE:$<TARGET_FILE:X>
forced="$( (grep -oE '(force_load,|whole-archive[^$]*|WHOLEARCHIVE:)\\?\$<TARGET_FILE:[A-Za-z0-9_+-]+>' "$TARGETS" || true) \
           | sed -E 's#.*TARGET_FILE:([A-Za-z0-9_+-]+)>#\1#' | sort -u | tr '\n' ' ' )"
[ -n "$forced" ] || { echo "ERROR: no force-load entries found in $TARGETS — upstream changed its registration linkage; review REG_LIBS"; exit 1; }

# --- -gpu variants: move the requested delegates from EXCLUDE into the registration set ----
drop_word() { local out="" w; for w in $2; do [ "$w" = "$1" ] || out="$out $w"; done; echo "$out"; }
for d in ${MERGE_DELEGATES:-}; do
  in_list "$d" "$DELEGATE_REG_LIBS" || { echo "ERROR: MERGE_DELEGATES names '$d' — known delegates: $DELEGATE_REG_LIBS"; exit 1; }
  in_list "$d" "$forced" || { echo "ERROR: delegate $d requested but upstream does not force-load it in $TARGETS — was it built (EXECUTORCH_BUILD_*=ON)?"; exit 1; }
  REG_LIBS="$REG_LIBS $d"
  EXCLUDE_LIBS="$(drop_word "$d" "$EXCLUDE_LIBS")"
done
if [ -n "${MERGE_DELEGATES:-}" ]; then
  for dep in $DELEGATE_DEP_LIBS; do
    EXCLUDE_LIBS="$(drop_word "$dep" "$EXCLUDE_LIBS")"
    # A dependency upstream force-loads (e.g. libprotobuf-lite under the CoreML delegate) has
    # static initializers of its own and joins the blob; any other becomes on-demand.
    in_list "$dep" "$forced" && REG_LIBS="$REG_LIBS $dep"
  done
  echo "delegates requested: ${MERGE_DELEGATES} -> registration set: $REG_LIBS"
fi
bad=""
for f in $forced; do in_list "$f" "$REG_LIBS $EXCLUDE_LIBS" || bad="$bad $f"; done
if [ -n "$bad" ]; then
  echo "ERROR: upstream force-loads libraries this merge does not classify:$bad"
  echo "       add each to REG_LIBS (must register) or EXCLUDE_LIBS (must not) in $0"
  exit 1
fi
for r in $REG_LIBS; do in_list "$r" "$forced" || { echo "ERROR: $r is in REG_LIBS but upstream no longer force-loads it — review"; exit 1; }; done
echo "registration set verified against ExecuTorchTargets.cmake: $REG_LIBS"

# --- Member list from the exported IMPORTED_LOCATIONs ------------------------------------
# CMake writes the per-config locations into ExecuTorchTargets-<config>.cmake:
#   set_target_properties(X PROPERTIES\n  ...\n  IMPORTED_LOCATION_RELEASE "${_IMPORT_PREFIX}/lib/libX.a"
# The target name is on the set_target_properties line, the path a few lines below. Take
# the Release config (the only one we build; the iOS Xcode build is --config Release too).
LOCS="$PREFIX/lib/cmake/ExecuTorch/ExecuTorchTargets-release.cmake"
[ -f "$LOCS" ] || { echo "ERROR: $LOCS not found (expected a Release export)"; exit 1; }
awk '
  /set_target_properties\(/ { name=$1; sub(/.*set_target_properties\(/, "", name) }
  /IMPORTED_LOCATION_RELEASE/ { match($0, /"[^"]*"/); print name, substr($0, RSTART+1, RLENGTH-2) }
' "$LOCS" | sed "s#\${_IMPORT_PREFIX}#$PREFIX#g" | sort -u > "$WORK/members.txt"

REG_PATHS=(); REST=()
while read -r name path; do
  [ -n "$name" ] || continue
  case "$path" in *.a|*.lib) ;; *) continue ;; esac   # skip any shared/other locations
  [ -f "$path" ] || { echo "ERROR: $name -> $path (from ExecuTorchTargets.cmake) does not exist"; exit 1; }
  if in_list "$name" "$REG_LIBS $WHOLE_LIBS $CORE_LIBS"; then REG_PATHS+=("$path")
  elif in_list "$name" "$EXCLUDE_LIBS"; then :
  else REST+=("$path"); fi
done < "$WORK/members.txt"
[ "${#REG_PATHS[@]}" -eq "$(echo $REG_LIBS $WHOLE_LIBS $CORE_LIBS | wc -w | tr -d ' ')" ] || { echo "ERROR: not every REG_LIBS archive was exported: found ${REG_PATHS[*]:-none}"; exit 1; }
[ "${#REST[@]}" -gt 0 ] || { echo "ERROR: no on-demand archives exported"; exit 1; }
for a in ${MERGE_EXTRA_ARCHIVES:-}; do
  [ -f "$a" ] || { echo "ERROR: MERGE_EXTRA_ARCHIVES: $a does not exist"; exit 1; }
  REST+=("$a")
done

echo "blob archives — registrations + core + whole (partial-linked into one member):"; printf '  %s\n' "${REG_PATHS[@]}"
echo "on-demand archives (${#REST[@]}):"; printf '  %s\n' "${REST[@]}"

rm -f "$OUT"
case "$PLATFORM" in
  macos|ios)
    LD="${MERGE_LD:-ld}"
    REG_O="$WORK/executorch_registrations.o"
    # ld64 needs an explicit -arch for a partial link; read it off the first input (each
    # desktop/iOS leg is single-arch; the macOS universal archive is lipo'd from the
    # per-arch merged archives afterwards by CI).
    arch="$(lipo -archs "${REG_PATHS[0]}")"
    # ...and a -platform_version; read platform/minos/sdk off the same input's
    # LC_BUILD_VERSION so the blob carries exactly what the objects were built for.
    # (otool prints the platform numerically: 1 macOS, 2 iOS, 7 iOS simulator.)
    read -r bplat bmin bsdk <<EOF2
$(otool -l "${REG_PATHS[0]}" | awk '/LC_BUILD_VERSION/{f=1} f&&/ platform /{p=$2} f&&/ minos /{m=$2} f&&/ sdk /{print p, m, $2; exit}')
EOF2
    case "$bplat" in
      1|MACOS) bplat=macos ;; 2|IOS) bplat=ios ;; 7|IOSSIMULATOR) bplat=ios-simulator ;;
      *) echo "ERROR: unrecognised LC_BUILD_VERSION platform '$bplat' in ${REG_PATHS[0]}"; exit 1 ;;
    esac
    fl=(); for a in "${REG_PATHS[@]}"; do fl+=(-force_load "$a"); done
    # -keep_private_externs: by default `ld -r` demotes visibility=hidden (private extern)
    # symbols to plain locals, which would make the blob's own microkernels unresolvable
    # from XNNPACK's on-demand config objects; keep them private extern instead.
    "$LD" -r -keep_private_externs -arch "$arch" -platform_version "$bplat" "$bmin" "$bsdk" -o "$REG_O" "${fl[@]}"
    libtool -static -no_warning_for_no_symbols -o "$OUT" "$REG_O" "${REST[@]}"
    ;;
  linux|android)
    LD="${MERGE_LD:-}"
    if [ -z "$LD" ] && [ "$PLATFORM" = "android" ]; then
      : "${ANDROID_NDK_HOME:?ANDROID_NDK_HOME not set (needed for the NDK ld.lld)}"
      # (ld.lld is a symlink in the NDK — no -type f)
      LD="$(find "$ANDROID_NDK_HOME/toolchains/llvm/prebuilt" -maxdepth 3 -name 'ld.lld' | head -1)"
      [ -n "$LD" ] || { echo "ERROR: ld.lld not found under $ANDROID_NDK_HOME"; exit 1; }
    fi
    LD="${LD:-ld}"
    REG_O="$WORK/executorch_registrations.o"
    "$LD" -r -o "$REG_O" --whole-archive "${REG_PATHS[@]}" --no-whole-archive
    # GNU ar MRI script: addmod adds the blob as a member, addlib copies every member of
    # each input archive (duplicate basenames across libs are fine), then index.
    { echo "create $OUT"
      echo "addmod $REG_O"
      for a in "${REST[@]}"; do echo "addlib $a"; done
      echo save; echo end; } | ar -M
    ranlib "$OUT"
    ;;
  windows)
    # No partial link on COFF: the on-demand members go into executorch.lib, the blob set
    # (per-object) into executorch_registrations.lib for the consumer to /WHOLEARCHIVE.
    command -v lib.exe >/dev/null || { echo "ERROR: lib.exe not on PATH (run in MSVC env)"; exit 1; }
    # git-bash rewrites /nologo into a path ("C:\Program Files\Git\nologo"); the inputs are
    # already Windows paths via cygpath, so turn MSYS argument conversion off for lib.exe.
    export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'
    REGOUT="$(dirname "$OUT")/executorch_registrations.lib"; rm -f "$REGOUT"
    RSP="$WORK/libs.rsp"
    printf '/OUT:%s\n' "$(cygpath -w "$OUT")" > "$RSP"
    for a in "${REST[@]}"; do printf '"%s"\n' "$(cygpath -w "$a")" >> "$RSP"; done
    lib.exe /nologo "@$(cygpath -w "$RSP")"
    printf '/OUT:%s\n' "$(cygpath -w "$REGOUT")" > "$RSP"
    for a in "${REG_PATHS[@]}"; do printf '"%s"\n' "$(cygpath -w "$a")" >> "$RSP"; done
    lib.exe /nologo "@$(cygpath -w "$RSP")"
    echo "Wrote $REGOUT ($(du -h "$REGOUT" | cut -f1)) — link with /WHOLEARCHIVE"
    ;;
  *) echo "ERROR: unknown platform '$PLATFORM'"; exit 1 ;;
esac

rm -rf "$WORK"
echo "Wrote $OUT ($(du -h "$OUT" | cut -f1))"
