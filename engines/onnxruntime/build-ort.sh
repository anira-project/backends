#!/usr/bin/env bash
# Build static onnxruntime (FULL op set, CPU provider; GPU EPs only in -gpu variants) from source for one target,
# leaving the component .a/.lib for scripts/bundle-static.sh to merge into one lib.
#
# Ports olilarkin/ort-builder's recipe MINUS the op-reduction (no --minimal_build /
# --include_ops_by_config / --enable_reduced_operator_type_support / --disable_ml_ops),
# so every operator ships and any model works.
#
# Usage: build-ort.sh <platform> <arch> <config> <build-dir> [kind] [accel]
#   <platform>  macos | linux | windows | android | ios | ios-sim
#   <arch>      x86_64 | arm64 | aarch64 | arm64-v8a (android ABI)
#   <config>    Release | Debug      (Windows ships both; others Release)
#   <kind>      static (default) | shared. shared builds libonnxruntime.dylib/.so directly
#               (one self-contained lib — no re2 force-build, no bundling). We build SHARED
#               for macOS and for the Windows DML gpu variant; other Linux/Windows/Android
#               shared come from upstream prebuilts.
#   <accel>     none (default) | coreml | dml | webgpu, or a `+`-joined combination
#               (coreml+webgpu, dml+webgpu). GPU EPs ship ONLY in the separate -gpu
#               variant archives — CPU-only consumers get CPU-only packages, so default
#               builds carry no EP beyond CPU. A -gpu archive is "WebGPU + the platform's
#               native EP" (anira v3: WgpuBuffer is the portable fast domain, the native
#               EP the platform column).
#               coreml = macOS/iOS CoreML EP (--use_coreml), static + shared.
#               dml    = Windows DirectML EP (--use_dml), shared-only: Microsoft stopped
#               publishing the DirectML NuGet after 1.24.4, so the 1.26+ gpu variant is
#               built from source (dml.cmake nuget-restores the pinned Microsoft.AI.DirectML
#               redist itself).
#               webgpu = the WebGPU EP over an EXTERNAL Dawn (--use_webgpu
#               --use_external_dawn): ORT links only the dawn_proc thunks and the consumer
#               hands it a DawnProcTable at session creation (anira's Machine owns the one
#               Dawn of the process). The Dawn source is the revision ORT's cmake/deps.txt
#               pins; we build it here as the monolithic shared libwebgpu_dawn from that
#               same tree, so ORT, Dawn and the proc-table layout are one versioned triple.
#               Desktop only (macos/linux/windows).
set -euo pipefail

PLATFORM="${1:?platform}"; ARCH="${2:?arch}"; CONFIG="${3:-Release}"; OUT="${4:-build}"; KIND="${5:-static}"; ACCEL="${6:-none}"
HAS_COREML=0; HAS_DML=0; HAS_WEBGPU=0
IFS='+' read -r -a _accels <<< "$ACCEL"
for a in "${_accels[@]}"; do
  case "$a" in
    none|"") ;;
    coreml) HAS_COREML=1
      case "$PLATFORM" in macos|ios|ios-sim) ;; *) echo "ERROR: accel=coreml is Apple-only (macos/ios/ios-sim)"; exit 1 ;; esac ;;
    dml)    HAS_DML=1
      [ "$PLATFORM" = "windows" ] || { echo "ERROR: accel=dml is Windows-only (DirectML is a D3D12 API)"; exit 1; } ;;
    webgpu) HAS_WEBGPU=1
      case "$PLATFORM" in macos|linux|windows) ;; *) echo "ERROR: accel=webgpu is desktop-only for now (macos/linux/windows)"; exit 1 ;; esac ;;
    *) echo "ERROR: unknown accel '$a' in '$ACCEL'"; exit 1 ;;
  esac
done
HERE="$(cd "$(dirname "$0")" && pwd)"
VER="$(tr -d '[:space:]' < "$HERE/VERSION")"

# Ancient FetchContent deps still declare cmake_minimum_required(<3.5), which CMake 4.x
# refuses (psimd, pulled in via FP16 by --use_coreml, killed the -gpu macOS configure).
# Same policy floor the libtorch/tflite builders already set; no-op on modern deps.
export CMAKE_POLICY_VERSION_MINIMUM=3.5

# onnxruntime source at the pinned version; build.py FetchContents the rest.
SRC="$HERE/onnxruntime-src"
if [ ! -d "$SRC/.git" ]; then
  git clone --depth 1 --branch "v${VER}" https://github.com/microsoft/onnxruntime "$SRC"
fi

# Upstream CMake bugs hit by any STATIC --use_coreml build (macOS and iOS):
# 1) coreml_proto is installed but never added to the ${PROJECT_NAME}Targets export
#    set -> generate aborts ("requires target 'coreml_proto' that is not in any export
#    set"; providers_coreml + onnxruntime export-depend on it).
# 2) once exported, its PUBLIC include of ${CMAKE_CURRENT_BINARY_DIR} is a raw
#    build-dir path, illegal in an installed export -> wrap in $<BUILD_INTERFACE:>
#    (build behavior identical; our packaging bundles flat .a's, nothing ships the
#    export). Both idempotent (patterns don't rematch their replacements); perl for
#    BSD/GNU-sed neutrality.
if [ "$HAS_COREML" = 1 ]; then
  perl -pi -e 's/install\(TARGETS coreml_proto\s*$/install(TARGETS coreml_proto EXPORT \$\{PROJECT_NAME\}Targets\n/;
               s/^(\s+)"\$\{CMAKE_CURRENT_BINARY_DIR\}"\)\s*$/$1\$<BUILD_INTERFACE:\$\{CMAKE_CURRENT_BINARY_DIR\}>)\n/' \
    "$SRC/cmake/onnxruntime_providers_coreml.cmake"
fi

# --- WebGPU: Dawn at ORT's pin, built as the monolithic shared library ------------------
# Both the EP (external-Dawn ORT build: headers + dawn_proc from this tree) and the shipped
# libwebgpu_dawn come from ONE source tree at the revision ORT's cmake/deps.txt names, so a
# consumer can never pair a proc-table layout with the wrong Dawn. Per-target build/install
# dirs (the macOS x86_64 + arm64 legs share one cached source). The tag/hash of the pinned
# revision is exported as DAWN_REV for stage.sh to record in the package (DAWN_VERSION).
DAWN_SRC="$HERE/dawn-src"
DAWN_BUILD="$HERE/dawn-build-$PLATFORM-$ARCH"
DAWN_INSTALL="$HERE/dawn-install-$PLATFORM-$ARCH"
if [ "$HAS_WEBGPU" = 1 ]; then
  dawn_line="$(grep -E '^dawn;' "$SRC/cmake/deps.txt" | head -1)"
  [ -n "$dawn_line" ] || { echo "ERROR: no 'dawn;' entry in $SRC/cmake/deps.txt"; exit 1; }
  DAWN_URL="$(echo "$dawn_line" | cut -d';' -f2)"; DAWN_SHA1="$(echo "$dawn_line" | cut -d';' -f3 | tr -d '[:space:]')"
  DAWN_REV="$(basename "$DAWN_URL" .zip)"     # v20260818.211311 (tag) or a bare commit hash
  export DAWN_REV
  if [ ! -f "$DAWN_SRC/.anira-dawn-rev" ] || [ "$(cat "$DAWN_SRC/.anira-dawn-rev")" != "$DAWN_REV" ]; then
    echo "== fetching Dawn $DAWN_REV (ORT $VER deps.txt pin) =="
    rm -rf "$DAWN_SRC" "$HERE/dawn-dl"; mkdir -p "$HERE/dawn-dl"
    curl -fsSL -o "$HERE/dawn-dl/dawn.zip" "$DAWN_URL"
    got="$( (shasum -a 1 "$HERE/dawn-dl/dawn.zip" 2>/dev/null || sha1sum "$HERE/dawn-dl/dawn.zip") | cut -d' ' -f1)"
    [ "$got" = "$DAWN_SHA1" ] || { echo "ERROR: Dawn archive sha1 $got != pinned $DAWN_SHA1"; exit 1; }
    ( cd "$HERE/dawn-dl" && cmake -E tar xf dawn.zip )
    d="$(find "$HERE/dawn-dl" -mindepth 1 -maxdepth 1 -type d | head -1)"
    mv "$d" "$DAWN_SRC"; rm -rf "$HERE/dawn-dl"
    # ORT's own Dawn fetch runs Dawn's dependency script (DAWN_FETCH_DEPENDENCIES=ON); with a
    # custom source path it turns that OFF and expects the tree to be complete — so fetch here.
    ( cd "$DAWN_SRC" && "${PYTHON:-python3}" tools/fetch_dawn_dependencies.py )
    echo "$DAWN_REV" > "$DAWN_SRC/.anira-dawn-rev"
  fi

  # Monolithic SHARED Dawn (the flags mirror ORT's cmake/external/onnxruntime_external_deps.cmake
  # for its bundled Dawn, minus what only the static-into-ORT shape needs). Backend per platform:
  # Vulkan on Linux, D3D12 on Windows (built DXC, as ORT does), Metal on macOS.
  DAWN_FLAGS=(
    -DCMAKE_BUILD_TYPE=Release
    -DCMAKE_INSTALL_PREFIX="$DAWN_INSTALL"
    -DBUILD_SHARED_LIBS=OFF
    -DDAWN_BUILD_MONOLITHIC_LIBRARY=SHARED
    -DDAWN_ENABLE_INSTALL=ON
    -DDAWN_FETCH_DEPENDENCIES=OFF
    -DDAWN_BUILD_SAMPLES=OFF -DDAWN_BUILD_TESTS=OFF -DTINT_BUILD_TESTS=OFF -DTINT_BUILD_CMD_TOOLS=OFF
    -DDAWN_ENABLE_NULL=OFF -DDAWN_BUILD_PROTOBUF=OFF -DDAWN_SUPPORTS_CXX_MODULES=OFF
    -DDAWN_ENABLE_DESKTOP_GL=OFF -DDAWN_ENABLE_OPENGLES=OFF -DDAWN_USE_GLFW=OFF -DDAWN_USE_WINDOWS_UI=OFF
    -DTINT_BUILD_GLSL_WRITER=OFF -DTINT_BUILD_GLSL_VALIDATOR=OFF
    -DDAWN_USE_X11=OFF -DDAWN_USE_WAYLAND=OFF -DDAWN_ENABLE_SPIRV_VALIDATION=OFF
    -DDAWN_DXC_ENABLE_ASSERTS_IN_NDEBUG=OFF
  )
  case "$PLATFORM" in
    linux)   DAWN_FLAGS+=(-DDAWN_ENABLE_VULKAN=ON) ;;
    windows) DAWN_FLAGS+=(-DDAWN_ENABLE_D3D12=ON -DDAWN_ENABLE_D3D11=OFF -DDAWN_ENABLE_VULKAN=OFF -DDAWN_USE_BUILT_DXC=ON -DTINT_BUILD_HLSL_WRITER=ON) ;;
    macos)   DAWN_FLAGS+=(-DDAWN_ENABLE_METAL=ON -DCMAKE_OSX_ARCHITECTURES="$ARCH" -DCMAKE_OSX_DEPLOYMENT_TARGET=11.0) ;;
  esac
  if command -v sccache >/dev/null 2>&1 && [ "$PLATFORM" != "windows" ]; then
    DAWN_FLAGS+=(-DCMAKE_C_COMPILER_LAUNCHER=sccache -DCMAKE_CXX_COMPILER_LAUNCHER=sccache)
  fi
  echo "== building Dawn $DAWN_REV (monolithic shared) -> $DAWN_INSTALL =="
  rm -f "$DAWN_BUILD/CMakeCache.txt"; rm -rf "$DAWN_INSTALL"
  cmake -S "$DAWN_SRC" -B "$DAWN_BUILD" -G Ninja "${DAWN_FLAGS[@]}"
  cmake --build "$DAWN_BUILD" --target install -j
  find "$DAWN_INSTALL" -name 'libwebgpu_dawn*' -o -name 'webgpu_dawn.dll' -o -name 'webgpu_dawn.lib' | grep -q . || \
    { echo "ERROR: Dawn build installed no webgpu_dawn library under $DAWN_INSTALL"; exit 1; }
fi

ARGS=(
  --build_dir "$OUT"
  --config "$CONFIG"
  --parallel
  --skip_tests
  --compile_no_warning_as_error
  # Force re2 to build from source on every platform. Otherwise FetchContent's
  # FIND_PACKAGE_ARGS picks up a prebuilt re2 (e.g. vcpkg's on the Windows runners),
  # so no re2 build target is generated and the force-build below fails (MSB1009) —
  # and a prebuilt re2 wouldn't be in our static bundle anyway. (No-op on Linux/macOS,
  # which already build it from source.)
  #
  # onnxruntime_ENABLE_MEMLEAK_CHECKER: build.py turns this ON for Debug, which makes
  # the process abort at exit over onnxruntime's never-freed global singletons — i.e.
  # a Debug lib that crashes on normal teardown (smoke prints PASS, then exits 127).
  # It's an internal test aid; force OFF so the shipped Debug lib exits cleanly.
  #
  # onnxruntime_ENABLE_LTO=OFF: pin LTO off so MSVC never adds /GL + /LTCG (which
  # bloat the Windows static libs — the reason ort-builder ships ltcg_patch_for_windows).
  # In 1.26 /GL is gated entirely on this flag (cmake/adjust_global_compile_flags.cmake),
  # so this *is* the patch's net effect — the literal patch no longer applies (the
  # forced-LTO block it deletes was removed upstream). Explicit here, not build.py's default.
  #
  # onnxruntime_USE_TELEMETRY=OFF: 1.30 can compile Microsoft's 1DS client telemetry into the
  # runtime on every platform (a network-reporting SDK that pulls Network.framework on Apple
  # and an HTTP transport on Linux into the static bundle). anira packages report nothing —
  # force it off explicitly, whatever build.py's default.
  --cmake_extra_defines onnxruntime_BUILD_UNIT_TESTS=OFF CMAKE_DISABLE_FIND_PACKAGE_re2=ON onnxruntime_ENABLE_MEMLEAK_CHECKER=OFF onnxruntime_ENABLE_LTO=OFF onnxruntime_USE_TELEMETRY=OFF
)

# Shared build → one self-contained libonnxruntime.dylib/.so (re2 etc. linked in).
[ "$KIND" = "shared" ] && ARGS+=(--build_shared_lib)

# WebGPU EP over the external Dawn built above: ORT takes the headers + dawn_proc from our
# Dawn tree (onnxruntime_CUSTOM_DAWN_SRC_PATH; ORT then skips its own dependency fetch) and
# links no dawn_native — the consumer passes ep.webgpuexecutionprovider.dawnProcTable.
if [ "$HAS_WEBGPU" = 1 ]; then
  ARGS+=(--use_webgpu --use_external_dawn --cmake_extra_defines "onnxruntime_CUSTOM_DAWN_SRC_PATH=$DAWN_SRC")
fi

case "$PLATFORM" in
  macos)
    # Keep system packages (Homebrew abseil/protobuf/flatbuffers) out of the build so
    # onnxruntime uses its own bundled versions — else find_package picks them up and
    # generated headers clash (protobuf "undeclared Arena", flatbuffers version assert).
    # ORT_IGNORE_PATHS adds machine-specific prefixes (e.g. a local Android SDK).
    # IGNORE_PATH covers find_library/find_path (abseil/protobuf); IGNORE_PREFIX_PATH
    # covers find_package CONFIG mode (flatbuffers_DIR) — both needed.
    IGNORE="/opt/homebrew;/usr/local${ORT_IGNORE_PATHS:+;$ORT_IGNORE_PATHS}"
    # CoreML EP (GPU/ANE) — gpu variant only (GPU is always a separate archive; the
    # default macOS packages stay CPU-only). Static gpu consumers must link
    # CoreML.framework. (The coreml_proto export patch is applied post-clone above,
    # shared with the iOS coreml slices.)
    [ "$HAS_COREML" = 1 ] && ARGS+=(--use_coreml)
    ARGS+=(--cmake_extra_defines "CMAKE_OSX_ARCHITECTURES=$ARCH" "CMAKE_OSX_DEPLOYMENT_TARGET=11.0" \
           "CMAKE_IGNORE_PATH=$IGNORE" "CMAKE_IGNORE_PREFIX_PATH=$IGNORE")
    ;;
  linux) ;;     # native arch
  windows)
    # Build with Ninja + cl (MSVC env from ilammy/msvc-dev-cmd), NOT build.py's default
    # "Visual Studio 17 2022" generator: the windows runner images now ship VS 18, and the
    # hardcoded VS-2022 generator fails with "could not find any instance of Visual Studio".
    # Ninja+cl is generator/VS-version agnostic (and is what every other leg already uses).
    ARGS+=(--cmake_generator Ninja)
    # win-arm64: KleidiAI/SVE ship .S microkernels that CMake assembles with armasm64.exe,
    # which rejects the /arch:armv8.2 flag emitted for them (error A2029). They're optional
    # ARM CPU-matmul accelerators; disable on win-arm64 for a working CPU build. The other
    # arm64 targets (linux/macOS/android) assemble these with clang and keep them.
    [ "$ARCH" = "arm64" ] && ARGS+=(--cmake_extra_defines onnxruntime_USE_KLEIDIAI=OFF onnxruntime_USE_SVE=OFF)
    # DirectML EP (gpu variant, shared-only): vendor-agnostic Windows GPU via D3D12.
    # dml.cmake (Public mode) nuget-restores the pinned Microsoft.AI.DirectML redist into
    # <build>/packages/ — stage.sh ships its DirectML.dll next to onnxruntime.dll.
    if [ "$HAS_DML" = 1 ]; then
      [ "$KIND" = "shared" ] || { echo "ERROR: accel=dml is shared-only (DML EP + DirectML.dll redist)"; exit 1; }
      ARGS+=(--use_dml)
    fi
    # build.py forces CMAKE_MSVC_DEBUG_INFORMATION_FORMAT=ProgramDatabase (/Zi)
    # GLOBALLY — even for Release, which embeds CodeView in every .obj and bloats the
    # shipped static .lib ~5x (854 MB!). The Release lib we ship needs no debug info,
    # so override to none. (Debug keeps it — that's the point of the -debug variant.)
    [ "$CONFIG" = "Release" ] && ARGS+=(--cmake_extra_defines "CMAKE_MSVC_DEBUG_INFORMATION_FORMAT=")
    ;;
  android)
    # https://onnxruntime.ai/docs/build/android.html — arch is the ABI (arm64-v8a / x86_64)
    : "${ANDROID_NDK_HOME:?ANDROID_NDK_HOME not set}"
    ARGS+=(--android --android_abi "$ARCH" --android_api 27 --android_ndk_path "$ANDROID_NDK_HOME"
           ${ANDROID_SDK_ROOT:+--android_sdk_path "$ANDROID_SDK_ROOT"})
    ;;
  ios)
    ARGS+=(--ios --use_xcode --apple_sysroot iphoneos --osx_arch "$ARCH" --apple_deploy_target 13.0 --build_apple_framework)
    [ "$HAS_COREML" = 1 ] && ARGS+=(--use_coreml)   # iOS -gpu xcframework (GPU/ANE)
    ;;
  ios-sim)
    ARGS+=(--ios --use_xcode --apple_sysroot iphonesimulator --osx_arch "$ARCH" --apple_deploy_target 13.0 --build_apple_framework)
    [ "$HAS_COREML" = 1 ] && ARGS+=(--use_coreml)
    ;;
  wasm)
    # --build_wasm_static_lib bundles EVERY transitive dep (onnx/protobuf/re2/mlas/xnnpack)
    # into one self-contained libonnxruntime_webassembly.a via emar (onnxruntime_webassembly.cmake
    # bundle_static_library) — so the wasm leg needs neither the re2 force-build nor
    # scripts/bundle-static.sh below. build.py installs+activates its OWN pinned emsdk (4.0.23)
    # from the cmake/external/emsdk submodule (hardcoded toolchain path), so init it first —
    # the shallow clone above fetches no submodules. simd + threads (the ort-builder recipe);
    # threads => the consumer must link -pthread on a cross-origin-isolated (COOP/COEP) page.
    git -C "$SRC" submodule update --init --depth 1 cmake/external/emsdk
    ARGS+=(--build_wasm_static_lib --enable_wasm_simd --enable_wasm_threads --disable_rtti)
    ;;
  *) echo "ERROR: unknown platform '$PLATFORM'"; exit 1 ;;
esac

echo "+ build.py ${ARGS[*]}"
"${PYTHON:-python3}" "$SRC/tools/ci_build/build.py" "${ARGS[@]}"

# re2 is declared EXCLUDE_FROM_ALL and only *include*-attached to onnxruntime
# (cmake/onnxruntime_providers_cpu.cmake: onnxruntime_add_include_to_target ... re2::re2)
# on every non-WinML target — so the normal build NEVER compiles it. onnxruntime's
# shared lib links it into the final .dylib/.so itself (the shared link pulls it in,
# and macOS errors on undefined symbols), so this is ONLY needed for the STATIC bundle,
# which collects component .a and would otherwise miss libre2.a.
if [ "$KIND" = "shared" ]; then
  echo "onnxruntime $VER ($PLATFORM/$ARCH/$CONFIG, shared) built -> $OUT/$CONFIG"
  exit 0
fi
if [ "$PLATFORM" = "wasm" ]; then
  # --build_wasm_static_lib already produced a self-contained libonnxruntime_webassembly.a.
  echo "onnxruntime $VER (wasm static lib) built -> $OUT/$CONFIG"
  exit 0
fi
echo "+ force-build re2 (static bundle needs libre2.a / re2.lib)"
# re2 is fetched from source (CMAKE_DISABLE_FIND_PACKAGE_re2=ON + onnxruntime_USE_VCPKG=OFF).
# With Ninja on every platform, the target builds by name (the old Windows msbuild-by-path
# workaround for the VS generator's MSB1009 is no longer needed).
cmake --build "$OUT/$CONFIG" --config "$CONFIG" --target re2

echo "onnxruntime $VER ($PLATFORM/$ARCH/$CONFIG) built -> $OUT/$CONFIG"
