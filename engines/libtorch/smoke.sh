#!/usr/bin/env bash
# Uniform desktop smoke entry for libtorch: build the example via find_package(Torch) against
# the STAGED tree (the same path anira consumes) and run a real forward pass on native targets.
# libtorch is shared-only and uses a synthetic model (no external asset).
#
# Usage: smoke.sh <staging> <kind> <arch> <config> <can_run>
set -euo pipefail
ST="${1:?staging}"; KIND="${2:?kind}"; ARCH="${3:?arch}"; CONFIG="${4:?config}"; CANRUN="${5:?can_run}"
HERE="$(cd "$(dirname "$0")" && pwd)"

bash "$HERE/smoke-torch.sh" "$ST" "$HERE/test" "$CANRUN"
