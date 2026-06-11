#!/usr/bin/env bash
# iOS (litert): repackage Google's official prebuilt TensorFlowLiteC.xcframework (CPU, static,
# device + simulator). No build — the per-version download URL is read from the CocoaPods
# podspec. Smoke-gated on the simulator (real forward pass), then zipped into dist/<archive>.zip.
#
# Usage: ios.sh <archive-name>   (produces dist/<archive>.zip)
set -euo pipefail
ARCHIVE="${1:?archive name}"
HERE="$(cd "$(dirname "$0")" && pwd)"
VER="$(tr -d '[:space:]' < "$HERE/VERSION")"

# CocoaPods Specs shard for "TensorFlowLiteC" = 1/6/0
spec="https://raw.githubusercontent.com/CocoaPods/Specs/master/Specs/1/6/0/TensorFlowLiteC/${VER}/TensorFlowLiteC.podspec.json"
url="$(curl -fsSL "$spec" | python3 -c 'import json,sys; print(json.load(sys.stdin)["source"]["http"])')"
echo "framework url: $url"
curl -fsSL "$url" -o tflc.tar.gz
mkdir -p ex && tar -xzf tflc.tar.gz -C ex
xcf="$(find ex -maxdepth 4 -type d -name 'TensorFlowLiteC.xcframework' | head -1)"
[ -n "$xcf" ] || { echo "::error::TensorFlowLiteC.xcframework not found"; exit 1; }

echo "slices:"; ls "$xcf"
ls "$xcf" | grep -q 'ios-arm64'  || { echo "::error::no device (ios-arm64) slice"; exit 1; }
ls "$xcf" | grep -qi 'simulator' || { echo "::error::no simulator slice"; exit 1; }

# Smoke: compile + link smoke.cpp against the simulator slice, then RUN it on a booted sim
# and check the real forward pass (1->3, 3->9).
fw_dir="$(find "$xcf" -maxdepth 1 -type d -name '*simulator*' | head -1)"
sdk="$(xcrun --sdk iphonesimulator --show-sdk-path)"
clang++ -std=c++17 -arch arm64 -isysroot "$sdk" -mios-simulator-version-min=12.0 \
  -F "$fw_dir" -framework TensorFlowLiteC -framework Foundation \
  "$HERE/test/smoke.cpp" -o smoke_ios
curl -fsSL "https://raw.githubusercontent.com/tensorflow/tensorflow/v${VER}/tensorflow/lite/testdata/add.bin" -o add.bin
dev="$(xcrun simctl list devices available | grep -m1 -oE '[0-9A-F-]{36}')"
xcrun simctl boot "$dev" 2>/dev/null || true
xcrun simctl spawn "$dev" "$PWD/smoke_ios" "$PWD/add.bin"   # exits non-zero on wrong output

mkdir -p dist "staging/$ARCHIVE"
cp -R "$xcf" "staging/$ARCHIVE/"
( cd "staging/$ARCHIVE" && cmake -E tar cf "$OLDPWD/dist/$ARCHIVE.zip" --format=zip TensorFlowLiteC.xcframework )
echo "packaged dist/$ARCHIVE.zip"
