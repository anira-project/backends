#!/usr/bin/env bash
# Reduce a static archive to its public C API so it can coexist with other
# static engines in one consumer image.
#
# The self-contained static archives bundle their transitive dependency closure
# (XNNPACK, cpuinfo, pthreadpool, kleidiai, abseil, ...). Several engines vendor
# DIFFERENT versions of the SAME dependencies — ExecuTorch force-loads its own
# XNNPACK — so when a consumer links two such archives into one image the
# duplicate globals either hard-collide at link time or silently cross-bind
# between mismatched copies. Shipping archives whose only external symbols are
# the engine's public API removes both failure modes at the source.
#
# Per object format:
#   Mach-O  ld -r -force_load + -exported_symbols_list: merges the members into
#           one relocatable object, resolving internal references member-to-
#           member; non-exported globals become private extern, which -r writes
#           out as LOCAL symbols. Result is re-wrapped into an archive.
#   ELF     ld -r --whole-archive + objcopy --wildcard --keep-global-symbols:
#           same merge, then every global not matching the keep pattern is
#           demoted to local. Re-wrapped into an archive.
#   COFF    no partial link exists, so internals are RENAMED instead of
#           localized: every defined external not matching the keep prefix gets
#           the rename prefix, rewritten member-by-member with llvm-objcopy
#           --redefine-syms. Definitions and references rename consistently, so
#           cross-member references keep resolving inside the archive.
#           Undefined externals (CRT/OS imports) are untouched.
#
# Usage: isolate-static.sh <archive> <keep-prefixes> <rename-prefix> [output] [format]
#   <archive>        input static archive (.a / .lib)
#   <keep-prefixes>  comma-separated public API symbol prefixes to keep external
#                    (e.g. "LiteRt,TfLite" — LiteRT also publicly exposes the
#                    TfLite* delegate API, which its Windows headers dllexport)
#   <rename-prefix>  prefix for renamed internals (COFF flavor only)
#   [output]         output path; defaults to <archive> (in-place)
#   [format]         macho | elf | coff; default: .lib -> coff, .a -> host OS
# Env overrides: NM, OBJCOPY, LD, AR, MINOS (Mach-O -platform_version, default 11.0)
#
# The script self-audits: it fails if any defined external symbol outside the
# kept API survives.  bash 3.2 compatible (macOS /bin/bash).
set -euo pipefail

IN="${1:?archive}"; KEEP="${2:?keep prefixes}"; PFX="${3:?rename prefix}"
OUT="${4:-$IN}"; FORMAT="${5:-}"

# "A,B" -> grep -E alternation "^(A|B)" for the filters below.
KEEP_RE="^($(printf '%s' "$KEEP" | sed 's/,/|/g'))"

if [ -z "$FORMAT" ]; then
    case "$IN" in
        *.lib) FORMAT=coff ;;
        *) case "$(uname -s)" in
               Darwin) FORMAT=macho ;;
               *)      FORMAT=elf ;;
           esac ;;
    esac
fi

NM="${NM:-llvm-nm}"
command -v "$NM" >/dev/null 2>&1 || NM=nm

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

case "$FORMAT" in
macho)
    # Single-arch archives only (universal aggregation happens after staging).
    ARCH="$(lipo -info "$IN" | sed 's/.*architecture: //;s/.*are: //' | awk '{print $1}')"
    printf '%s' "$KEEP" | tr ',' '\n' | sed 's/^/_/;s/$/*/' > "$WORK/keep.exp"
    ld -r -arch "$ARCH" -platform_version macos "${MINOS:-11.0}" "${MINOS:-11.0}" \
        -force_load "$IN" -exported_symbols_list "$WORK/keep.exp" -o "$WORK/merged.o"
    ${AR:-ar} rcs "$WORK/out.a" "$WORK/merged.o"
    ;;
elf)
    printf '%s' "$KEEP" | tr ',' '\n' | sed 's/$/*/' > "$WORK/keep.txt"
    "${LD:-ld}" -r -o "$WORK/merged.o" --whole-archive "$IN" --no-whole-archive
    "${OBJCOPY:-objcopy}" --wildcard --keep-global-symbols="$WORK/keep.txt" "$WORK/merged.o"
    ${AR:-ar} rcs "$WORK/out.a" "$WORK/merged.o"
    ;;
coff)
    "$NM" --defined-only --extern-only "$IN" \
        | awk 'NF>=3 {print $3}' | sort -u | grep -Ev "$KEEP_RE" \
        | awk -v p="$PFX" '{print $0" "p$0}' > "$WORK/rename.map"
    [ -s "$WORK/rename.map" ] || { echo "isolate-static: empty rename map for $IN" >&2; exit 1; }
    "${OBJCOPY:-llvm-objcopy}" "--redefine-syms=$WORK/rename.map" "$IN" "$WORK/out.a"
    ;;
*)
    echo "isolate-static: unknown format '$FORMAT'" >&2; exit 1 ;;
esac

# Audit: no defined external symbol outside the kept API (COFF: or the rename
# prefix) may survive. nm prints "addr type name"; member headers/blanks differ.
LEFT="$("$NM" --defined-only --extern-only "$WORK/out.a" 2>/dev/null \
    | awk 'NF>=3 {print $3}' | sed 's/^_//' \
    | grep -Ev "$KEEP_RE" | grep -v "^$PFX" | grep -cv '^$' || true)"
if [ "$LEFT" != "0" ]; then
    echo "isolate-static: $LEFT non-API globals survived in $OUT" >&2
    exit 1
fi

mkdir -p "$(dirname "$OUT")"
mv -f "$WORK/out.a" "$OUT"
echo "isolate-static: $IN -> $OUT (only {${KEEP}}* external, format $FORMAT)"
