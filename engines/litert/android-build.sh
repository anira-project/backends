#!/usr/bin/env bash
# Build a static libLiteRt.a for ONE Android ABI, run INSIDE LiteRT's ml-build container
# (us-docker.pkg.dev/ml-oss-artifacts-published/ml-public-container/ml-build). A bare-runner Android
# Bazel build fails at the TF-workspace cuda_redist / rules_ml_toolchain external-load; the ml-build
# container provisions those. This installs the NDK (r25b, matching LiteRT's ci/tflite-android
# Dockerfile), configures the Android workspace, builds the C API impl cc_library closure, and
# merges its transitive static archives into one libLiteRt.a.
#
# Mounts (from the host docker run): /src = litert-src (Bazel workspace), /out = staging prefix.
# Usage (inside container): android-build.sh <abi>   where <abi> = arm64-v8a | x86_64
set -euo pipefail
ABI="${1:?abi: arm64-v8a|x86_64}"
case "$ABI" in
  arm64-v8a) ACFG=android_arm64 ;;
  x86_64)    ACFG=android_x86_64 ;;
  *) echo "ERROR: unsupported ABI '$ABI'"; exit 1 ;;
esac

# --- Android NDK r25b (matches ci/tflite-android.Dockerfile) ------------------------------------
export ANDROID_DEV_HOME=/android
export ANDROID_SDK_HOME="$ANDROID_DEV_HOME/sdk"
export ANDROID_NDK_API_LEVEL=21 ANDROID_API_LEVEL=35 ANDROID_SDK_API_LEVEL=35 ANDROID_BUILD_TOOLS_VERSION=35.0.1
mkdir -p "$ANDROID_DEV_HOME" "$ANDROID_SDK_HOME"
if ! ls "$ANDROID_DEV_HOME"/android-ndk-*/toolchains >/dev/null 2>&1; then
  ( cd "$ANDROID_DEV_HOME"
    wget -q https://dl.google.com/android/repository/android-ndk-r25b-linux.zip
    unzip -q android-ndk-r25b-linux.zip )
fi
# Point ANDROID_NDK_HOME at the extracted dir — match the DIRECTORY only (a bare android-ndk-*
# glob also matches the downloaded .zip, yielding two paths).
export ANDROID_NDK_HOME="$(find "$ANDROID_DEV_HOME" -maxdepth 1 -type d -name 'android-ndk-*' | head -1)"
[ -d "$ANDROID_NDK_HOME/toolchains" ] || { echo "ERROR: NDK missing at '$ANDROID_NDK_HOME'"; ls -la "$ANDROID_DEV_HOME"; exit 1; }

# --- Android SDK: configure.py's TF_SET_ANDROID_WORKSPACE sets up the android_sdk_repository too,
# and prompts (fatally) for a build-tools/platform it can't find. Install cmdline-tools + the
# platform + build-tools (needs a JDK for sdkmanager). ANDROID_HOME/SDK_HOME + the version env
# vars then make configure.py non-interactive.
command -v java >/dev/null 2>&1 || { apt-get update -y && apt-get install -y default-jdk; }
if [ ! -d "$ANDROID_SDK_HOME/cmdline-tools/latest/bin" ]; then
  ( cd /tmp
    wget -q https://dl.google.com/android/repository/commandlinetools-linux-13114758_latest.zip -O cmdtools.zip
    unzip -q cmdtools.zip
    mkdir -p "$ANDROID_SDK_HOME/cmdline-tools"
    mv cmdline-tools "$ANDROID_SDK_HOME/cmdline-tools/latest" )
fi
export ANDROID_HOME="$ANDROID_SDK_HOME"
sdkmgr="$ANDROID_SDK_HOME/cmdline-tools/latest/bin/sdkmanager"
yes | "$sdkmgr" --sdk_root="$ANDROID_SDK_HOME" --licenses >/dev/null 2>&1 || true
"$sdkmgr" --sdk_root="$ANDROID_SDK_HOME" "platform-tools" \
  "platforms;android-${ANDROID_API_LEVEL}" "build-tools;${ANDROID_BUILD_TOOLS_VERSION}" >/dev/null

cd /src

# --- configure.py: host CC toolchain + Android workspace ----------------------------------------
# The ml-build container builds with clang; configure.py prompts for CLANG_COMPILER_PATH and errors
# ("Invalid CLANG_COMPILER_PATH ... 10 times") if `yes ""` just feeds blanks — set it from env.
export PYTHON_BIN_PATH="$(python3 -c 'import sys; print(sys.executable)')"
export TF_NEED_ROCM=0 TF_NEED_CUDA=0 CC_OPT_FLAGS='-Wno-sign-compare'
export TF_SET_ANDROID_WORKSPACE=1
export TF_NEED_CLANG=1
# The base ml-build image has no clang (verified) — install it. (NB: a bare `ls glob | sort | tail`
# here exits 2 when the glob doesn't match and, under set -e + pipefail, kills the script with no
# output — guard every such lookup with `|| true`.)
clang_path="$(command -v clang clang-18 clang-17 2>/dev/null | head -1 || true)"
if [ ! -x "$clang_path" ]; then
  echo "clang not in image — installing via apt"
  apt-get update -y && apt-get install -y clang
  clang_path="$(command -v clang || true)"
fi
[ -x "$clang_path" ] || { echo "ERROR: no clang available in container"; exit 1; }
export CLANG_COMPILER_PATH="$clang_path"
echo "using CLANG_COMPILER_PATH=$CLANG_COMPILER_PATH"
{ set +o pipefail; yes "" | python3 configure.py; }   # yes SIGPIPEs (141) under pipefail

defines=(--define=litert_disable_gpu=true --define=litert_disable_npu=true)
target=//litert/c:litert_runtime_c_api_so_shim

# Build the impl closure (compiles every transitive dep), then materialise each cc_library's
# archive (the top build leaves them as .o), then merge the static-archive closure into libLiteRt.a.
bazel build "--config=$ACFG" "${defines[@]}" "$target"
bazel cquery "--config=$ACFG" "${defines[@]}" "kind('cc_library rule', deps($target))" \
  --output=label 2>/dev/null | awk 'NF{print $1}' | sort -u > /tmp/labels.txt
xargs bazel build "--config=$ACFG" "${defines[@]}" < /tmp/labels.txt
cat > /tmp/collect.star <<'STAR'
def format(target):
    ps = providers(target)
    cc = ps.get("CcInfo") if ps else None
    if cc == None:
        return ""
    out = []
    for li in cc.linking_context.linker_inputs.to_list():
        for lib in li.libraries:
            for f in [lib.pic_static_library, lib.static_library]:
                if f != None:
                    out.append(f.path)
    return "\n".join(out)
STAR
bazel cquery "--config=$ACFG" "${defines[@]}" "$target" \
  --output=starlark --starlark:file=/tmp/collect.star 2>/dev/null | grep -v '^$' | sort -u > /tmp/all.txt
execroot="$(bazel info execution_root)"
: > /tmp/archives.txt
while IFS= read -r a; do [ -f "$execroot/$a" ] && printf '%s\n' "$a" >> /tmp/archives.txt; done < /tmp/all.txt
count="$(wc -l < /tmp/archives.txt | tr -d ' ')"
[ "$count" -gt 0 ] || { echo "ERROR: no static archives materialised"; exit 1; }
echo "android $ABI: merging $count transitive archives -> libLiteRt.a"

mkdir -p /out/lib
{ echo "create /out/lib/libLiteRt.a"
  awk -v r="$execroot" '{print "addlib "r"/"$0}' /tmp/archives.txt
  echo save; echo end; } | ar -M
ranlib /out/lib/libLiteRt.a
echo "built android $ABI static libLiteRt.a ($(du -h /out/lib/libLiteRt.a | cut -f1))"
