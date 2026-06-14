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

# --- Android NDK r25b + SDK cmdline-tools (mirrors ci/tflite-android.Dockerfile) ----------------
export ANDROID_DEV_HOME=/android
export ANDROID_NDK_HOME="$ANDROID_DEV_HOME/ndk"
export ANDROID_SDK_HOME="$ANDROID_DEV_HOME/sdk"
export ANDROID_NDK_API_LEVEL=21 ANDROID_API_LEVEL=35 ANDROID_SDK_API_LEVEL=35 ANDROID_BUILD_TOOLS_VERSION=35.0.1
if [ ! -d "$ANDROID_NDK_HOME/toolchains" ]; then
  mkdir -p "$ANDROID_DEV_HOME"
  ( cd "$ANDROID_DEV_HOME"
    wget -q https://dl.google.com/android/repository/android-ndk-r25b-linux.zip
    unzip -q android-ndk-r25b-linux.zip && ln -s "$ANDROID_DEV_HOME"/android-ndk-* "$ANDROID_NDK_HOME" )
fi
mkdir -p "$ANDROID_SDK_HOME"

cd /src

# --- configure.py: host CC toolchain + Android workspace ----------------------------------------
export PYTHON_BIN_PATH="$(python3 -c 'import sys; print(sys.executable)')"
export TF_NEED_ROCM=0 TF_NEED_CUDA=0 CC_OPT_FLAGS='-Wno-sign-compare'
export TF_SET_ANDROID_WORKSPACE=1
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
