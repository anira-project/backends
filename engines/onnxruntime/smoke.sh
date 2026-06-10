#!/usr/bin/env bash
# Uniform desktop smoke entry for onnxruntime: compile+link the example against the STAGED
# archive (proves the static lib is symbol-complete) and run a real forward pass on native
# targets (add.onnx: y=x+x, {1,2,3} -> {2,4,6}). add.onnx is checked in at test/.
#
# Usage: smoke.sh <staging> <kind> <arch> <config> <can_run>
set -euo pipefail
ST="${1:?staging}"; KIND="${2:?kind}"; ARCH="${3:?arch}"; CONFIG="${4:?config}"; CANRUN="${5:?can_run}"
HERE="$(cd "$(dirname "$0")" && pwd)"

# smoke-onnx.sh takes an optional trailing "shared" to link the .dylib/.so instead of the .a.
extra=""; [ "$KIND" = "shared" ] && extra="shared"
bash "$HERE/smoke-onnx.sh" "$ST" "$HERE/test/smoke.cpp" "$ARCH" "$CONFIG" "$CANRUN" $extra
