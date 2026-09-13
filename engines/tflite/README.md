# TensorFlow Lite (C API)

Builds `libtensorflowlite_c` from upstream `tensorflow/lite/c` at the version in
[`VERSION`](./VERSION), packaged for [anira](https://github.com/anira-project/anira).
CPU only (XNNPACK) by default; GPU delegates ship as separate `-gpu` archives.

## `-gpu` variants

- **macOS** (x86_64 + arm64, shared + static): the **Metal GPU delegate** (`TFLGpuDelegate*`,
  `TFLITE_BUILD_METAL_DELEGATE`). Experimental — upstream only tests it on iOS. The shared lib
  force-loads `metal_delegate` and exports `_TFLGpuDelegate*`; the smoke runs `add.bin` through
  the delegate on the runner's real Metal device.
- **Android** (arm64-v8a + x86_64, multi-ABI `-gpu` bundles, shared + static): the official
  **OpenCL GPU delegate** (`TfLiteGpuDelegateV2*`, `TFLITE_BUILD_GPU_DELEGATE`). Upstream's
  CMake source list omits the Android-only async/EGL/AHardwareBuffer helpers `delegate.cc`
  needs, so `CMakeLists.txt` adds them and links `EGL` + `GLESv3` (OpenCL and `libandroid` are
  dlopen'd). The smoke is a link-level proof (it references the entry point).
- **iOS** `-gpu` xcframework: Google's official `TensorFlowLiteCMetal` +
  `TensorFlowLiteCCoreML` delegate xcframeworks next to `TensorFlowLiteC` (`ios.sh gpu`).

Linux/Windows have no `-gpu`: the desktop OpenCL delegate is unsupported upstream (use LiteRT's
WebGPU accelerator for that runtime on desktop).

## Consuming the Windows `static` lib

- `-DTFL_STATIC_LIBRARY_BUILD` — else the C-API header uses `__declspec(dllimport)` (link fails).
- match the CRT — `/MD` for `-static`, `/MDd` for `-static-debug` (cl defaults to `/MT` → `LNK2038`).
- link `advapi32.lib` (cpuinfo's registry calls) + the matching `ucrt[d].lib`.

## Files

| File                      | Purpose                                          |
| ------------------------- | ------------------------------------------------ |
| `VERSION`                 | Pinned upstream version (single source of truth) |
| `CMakeLists.txt`          | Fetch tensorflow, build + install the C API      |
| `CMakePresets.json`       | Standalone tflite presets (bases in `presets-base.json`) |
| `presets-base.json`       | Hidden platform/kind bases, shared with the root presets |
| `ios.sh`                  | Repackage Google's `TensorFlowLiteC.xcframework` |
| `test/CMakeLists.txt`     | CMake smoke (run via the smoke action / ctest)   |
| `test/smoke.cpp`          | Forward-pass smoke (`add.bin` → `{3,9}`)         |

> iOS isn't built here — it repackages Google's prebuilt `TensorFlowLiteC.xcframework`
> (the `ios-xcframework` job in `_build-backend.yml`).

## Local build

```bash
cmake --preset macos-arm64-shared      # or *-static, linux-x64-shared, … (cmake --list-presets)
cmake --build --preset macos-arm64-shared -j
cmake --install build/macos-arm64-shared --prefix /tmp/out   # -> /tmp/out/{include,lib}
```

Android needs `ANDROID_NDK_HOME`; wasm needs `EMSDK` (4.0.23, to match anira-web's ABI).

## Build notes

- **Windows Debug** uses `/Z7` (no PDB → no `C1041`); no sccache for Debug.
- **Windows arm64** disables XNNPACK (MSVC can't build its NEON microkernels) → reference kernels.
  Building this leg with clang-cl was explored to re-enable XNNPACK: clang-cl does compile the
  baseline NEON microkernels, but the pinned XNNPACK/cpuinfo predate Windows-arm64 support (XNNPACK
  applies its per-file `-march=armv8.2+fp16/dotprod` flags only for non-MSVC compilers; cpuinfo
  doesn't compile its arm/Windows source) — so it needs multi-dep overrides upstream. Left on the
  reference-kernel build; revisit when TFLite bumps to an XNNPACK/cpuinfo with arm64-Windows support.
- **macOS x86_64 / iOS-sim x86_64** force `CMAKE_SYSTEM_PROCESSOR` so TFLite fetches the
  NEON_2_SSE shim x86 needs (Apple keeps `CMAKE_SYSTEM_PROCESSOR` as the host arch otherwise).
- **CMake 4 + old TFLite deps** need `CMAKE_POLICY_VERSION_MINIMUM=3.5` (set in the preset env).
- **Android smoke** links `-static-libstdc++` (no `libc++_shared.so` on the device).
- **Static bundling** merges the component archives wholesale: macOS `libtool`, Linux
  `ar -M`, Windows `lib.exe` (`scripts/bundle-static.sh`).
