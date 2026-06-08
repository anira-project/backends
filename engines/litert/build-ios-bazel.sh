#!/usr/bin/env bash
# iOS LiteRT (TensorFlow Lite C) build — Bazel path.
#
# iOS is the ONE target the TFLite/LiteRT CMake build does not support, so it is
# built with Bazel against the upstream framework target, then packaged into an
# .xcframework by shared/make-xcframework.sh.
#
# STATUS: STUB — wiring is in place; the exact Bazel invocation/output paths must
# be validated against the pinned TF version on the first CI run.
#
# Usage: build-ios-bazel.sh <tensorflow-src-dir> <out-dir>
set -euo pipefail

TF_SRC="${1:?path to tensorflow source}"
OUT="${2:?output dir}"
mkdir -p "$OUT"

# Device (arm64) + simulator framework. Upstream target:
#   //tensorflow/lite/ios:TensorFlowLiteC_framework
#
# TODO(verify): confirm target name/flags for v$(cat "$(dirname "$0")/VERSION"),
# and whether to emit a static framework. Reference:
#   https://www.tensorflow.org/lite/guide/build_ios
( cd "$TF_SRC"
  bazel build -c opt --config=ios_fat \
    //tensorflow/lite/ios:TensorFlowLiteC_framework
)

echo "TODO: copy bazel-bin framework(s) into $OUT and call shared/make-xcframework.sh"
exit 1
