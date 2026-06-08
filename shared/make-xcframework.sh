#!/usr/bin/env bash
# Combine per-slice iOS libraries (device arm64 + simulator arm64/x86_64) into a
# single .xcframework. Simulator slices are lipo'd into one fat lib first, since
# an xcframework allows at most one library per platform variant.
#
# Usage: make-xcframework.sh <out.xcframework> <device-lib> <sim-lib>...
#   <device-lib>  static .a (or framework) for iphoneos arm64
#   <sim-lib>...  one or more static .a for iphonesimulator (arm64, x86_64)
#
# TODO(verify): if iOS is built as a TensorFlowLiteC.framework via Bazel instead
# of a bare .a, pass the .framework paths and drop the lipo step.
set -euo pipefail

OUT="$1"; shift
DEVICE_LIB="$1"; shift
SIM_LIBS=("$@")

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

SIM_FAT="$WORK/sim/libtensorflowlite_c.a"
mkdir -p "$WORK/sim"
if [ "${#SIM_LIBS[@]}" -gt 1 ]; then
  lipo -create "${SIM_LIBS[@]}" -output "$SIM_FAT"
else
  cp "${SIM_LIBS[0]}" "$SIM_FAT"
fi

rm -rf "$OUT"
xcodebuild -create-xcframework \
  -library "$DEVICE_LIB" \
  -library "$SIM_FAT" \
  -output "$OUT"

echo "Created $OUT"
