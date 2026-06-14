#!/usr/bin/env bash
# iOS (litert): repackage the official prebuilt libLiteRt.dylib (device + simulator, arm64) from
# google-ai-edge/LiteRT's litert/prebuilt/ios_* (Git-LFS, via the media endpoint) into an
# .xcframework — LiteRT's native C API (LiteRt* symbols), CPU-only. Headers from litert_cc_sdk.zip.
# Produces dist/<archive>.zip.
#
# Usage: ios.sh <archive-name>
set -euo pipefail
ARCHIVE="${1:?archive name}"
HERE="$(cd "$(dirname "$0")" && pwd)"
VER="$(tr -d '[:space:]' < "$HERE/VERSION")"
PREBUILT_SHA="89c838788bba9c2ec6bbefd52971daf39d8e2856"
base="https://media.githubusercontent.com/media/google-ai-edge/LiteRT/${PREBUILT_SHA}/litert/prebuilt"

# Headers: SDK litert/c/*.h + synthesized CPU-only build_config.h (same set as the other legs).
sdk="$HERE/litert_cc_sdk"
if [ ! -d "$sdk/litert/c" ]; then
  curl -fsSL "https://github.com/google-ai-edge/LiteRT/releases/download/v${VER}/litert_cc_sdk.zip" -o "$HERE/litert_cc_sdk.zip"
  ( cd "$HERE" && cmake -E tar xf litert_cc_sdk.zip )
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

# Prebuilt dylibs: device (ios_arm64) + simulator (ios_sim_arm64). @rpath install_name so the
# consuming app embeds it normally.
mkdir -p dev sim
curl -fsSL "$base/ios_arm64/libLiteRt.dylib.lfs"     -o dev/libLiteRt.dylib
curl -fsSL "$base/ios_sim_arm64/libLiteRt.dylib.lfs" -o sim/libLiteRt.dylib
install_name_tool -id @rpath/libLiteRt.dylib dev/libLiteRt.dylib
install_name_tool -id @rpath/libLiteRt.dylib sim/libLiteRt.dylib
echo "device slices:"; lipo -info dev/libLiteRt.dylib; echo "sim slices:"; lipo -info sim/libLiteRt.dylib
# Verify the native C API is present (not a stub). Capture nm output to a file first — piping to
# `grep -q` closes the pipe early, which makes nm SIGPIPE and pipefail flag a false failure.
nm -gU dev/libLiteRt.dylib > "$HERE/ios_syms.txt" 2>/dev/null || true
grep -q LiteRtCreateEnvironment "$HERE/ios_syms.txt" || { echo "::error::libLiteRt missing LiteRtCreateEnvironment"; head "$HERE/ios_syms.txt"; exit 1; }

rm -rf LiteRt.xcframework
xcodebuild -create-xcframework \
  -library "$PWD/dev/libLiteRt.dylib" -headers "$hdr" \
  -library "$PWD/sim/libLiteRt.dylib" -headers "$hdr" \
  -output LiteRt.xcframework

mkdir -p dist "staging/$ARCHIVE"
cp -R LiteRt.xcframework "staging/$ARCHIVE/"
( cd "staging/$ARCHIVE" && cmake -E tar cf "$OLDPWD/dist/$ARCHIVE.zip" --format=zip LiteRt.xcframework )
echo "packaged dist/$ARCHIVE.zip"
