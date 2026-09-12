#!/usr/bin/env bash
# Demote STB_GNU_UNIQUE symbols to weak in every static archive under a dir.
#
# GCC emits inline-function locals and C++17 inline variables as GNU-unique
# symbols. Those are hostile to static-archive distribution: consumers that
# link the archive into a hidden-visibility shared object (audio plugins —
# JUCE/CLAP/Max externals) hit binutils' special unique-symbol handling and
# fail with undefined references to symbols the archive plainly defines
# (seen with Eigen's manage_caching_sizes cache and libstdc++'s
# piecewise_construct in the executorch/onnxruntime Linux archives; whether
# GCC emits them varies with the runner toolchain, which is how a rebuild of
# the same engine version regressed consumers). Weak binding is exactly the
# semantic these symbols have on every non-GNU toolchain, so demote them at
# packaging: list each archive's unique symbols and llvm-objcopy
# --weaken-symbols precisely those.
#
# ELF-only by nature (Mach-O and COFF have no STB_GNU_UNIQUE) — call it on
# Linux static legs. Clang-built archives (LiteRT) contain none: no-op.
#
# Usage: de-unique-static.sh <lib-dir>
# Env overrides: NM, OBJCOPY (default llvm-nm / llvm-objcopy)
set -euo pipefail

DIR="${1:?lib dir}"
# Prefer the LLVM tools, fall back to binutils (GNU nm prints the same 'u'
# for STB_GNU_UNIQUE and GNU objcopy supports --weaken-symbols).
NM="${NM:-llvm-nm}";           command -v "$NM"      >/dev/null 2>&1 || NM=nm
OBJCOPY="${OBJCOPY:-llvm-objcopy}"; command -v "$OBJCOPY" >/dev/null 2>&1 || OBJCOPY=objcopy

total=0
for a in "$DIR"/*.a; do
    [ -e "$a" ] || continue
    syms="$(mktemp)"
    # nm: "addr u name" for GNU-unique definitions; collect names. Tolerate
    # nm failing on foreign members (|| true keeps pipefail from killing us).
    { "$NM" "$a" 2>/dev/null || true; } | awk '$2 == "u" {print $3}' | sort -u > "$syms"
    n=$(grep -c . "$syms" || true)
    if [ "$n" != "0" ]; then
        "$OBJCOPY" "--weaken-symbols=$syms" "$a"
        left=$({ "$NM" "$a" 2>/dev/null || true; } | awk '$2 == "u"' | grep -c . || true)
        if [ "$left" != "0" ]; then
            echo "de-unique-static: $left unique symbols survived in $a" >&2
            rm -f "$syms"
            exit 1
        fi
        echo "de-unique-static: $(basename "$a"): $n unique symbol(s) -> weak"
        total=$((total + n))
    fi
    rm -f "$syms"
done
echo "de-unique-static: done ($total symbol(s) demoted under $DIR)"
