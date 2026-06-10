#!/usr/bin/env bash
# Uniform desktop smoke entry for litert: compile+link (and run on native targets) the
# example against the STAGED archive — the link proves the static lib is symbol-complete,
# the run does a real forward pass (add.bin: {1,3} -> {3,9}). add.bin is fetched from the
# tensorflow source at the pinned version (the staged archive ships no model).
#
# Usage: smoke.sh <staging> <kind> <arch> <config> <can_run>
set -euo pipefail
ST="${1:?staging}"; KIND="${2:?kind}"; ARCH="${3:?arch}"; CONFIG="${4:?config}"; CANRUN="${5:?can_run}"
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
VER="$(tr -d '[:space:]' < "$HERE/VERSION")"

model="$HERE/add.bin"
curl -fsSL "https://raw.githubusercontent.com/tensorflow/tensorflow/v${VER}/tensorflow/lite/testdata/add.bin" -o "$model"

bash "$ROOT/shared/smoke-test.sh" "$ST" "$HERE/test/smoke.cpp" "$model" "$KIND" "$ARCH" "$CANRUN" "$CONFIG"
