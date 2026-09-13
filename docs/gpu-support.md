# GPU support

Status: **shipped** for every backend (per-engine releases from 2026-09-13 on). The
remaining gaps are listed at the end.

## Principles

1. **CPU-only users get CPU-only packages.** GPU support is ALWAYS a separate variant
   archive (`-gpu` / `-cuda` name token) — never baked into the default packages. At
   typical audio buffer sizes, host↔device transfer latency and scheduling jitter
   usually make CPU inference faster and more predictable anyway; GPU variants target
   large models / relaxed-latency use cases. The default packages' smoke **asserts the
   accelerator is absent**.
2. **A variant is one extra build leg, not a new pipeline.** The accelerator is encoded
   in the preset's `vendor.anira.name` (e.g. `Windows-x86_64-gpu`), so archive naming,
   packaging, upload, smoke and publish all reuse the existing machinery. The preset's
   `BACKENDS_FLAVOR` cache var tells the engine's `stage.sh` what to build. Aggregation
   jobs (Android multi-ABI bundle, iOS xcframework) are variant-aware too:
   `<lib>-<ver>-Android-gpu-<kind>.zip`, `<lib>-<ver>-iOS-gpu-xcframework.zip`.
3. **`-gpu` = the cross-vendor WebGPU path plus the platform-native path** where the
   engine has one (anira v3's provider model: `WEBGPU` everywhere, `COREML` / `DIRECTML`
   / `VULKAN` / Metal natively). **`-cuda` = NVIDIA only**, repackaged from upstream's
   CUDA prebuilt.
4. **CUDA runtime + cuDNN are user-provided prerequisites**, documented per package —
   bundling them would push archives past GitHub's 2 GB release-file limit and multiply
   download size. `-cuda` packages need the NVIDIA libraries on the library path at
   runtime (and therefore skip the CI smoke: `canRun=0` where the dynamic loader would
   fail without them).

## Variant matrix

Everything below is published; `shared`/`static` as listed.

| Backend | macOS | Windows | Linux | Android | iOS |
|---|---|---|---|---|---|
| **ONNX Runtime** | `-gpu` (x86_64 + arm64, shared + static): **CoreML EP + WebGPU EP** (Metal) · from source. Requires macOS 13.3+ | `-gpu` (x86_64 + arm64, shared): **DirectML EP + WebGPU EP** (D3D12) · from source · `-cuda` (x86_64, shared): **CUDA EP**, repackaged upstream `gpu_cuda13` | `-gpu` (x86_64, shared + static): **WebGPU EP** (Vulkan) · from source · `-cuda` (x86_64, shared): **CUDA EP**, repackaged upstream `gpu_cuda13` | — (WebGPU EP over an NDK-built Dawn is the open item) | `-gpu` xcframework: **CoreML EP** |
| **LibTorch** | `-gpu` (arm64, shared): **MPS** · from source | `-cuda` (x86_64, shared): repackaged upstream `cu130`, NVIDIA redist libs stripped | `-cuda` (x86_64, shared): repackaged upstream `cu130`, NVIDIA redist libs stripped | — | — |
| **ExecuTorch** | `-gpu` (x86_64 + arm64, static): **CoreML + MPS** delegates, **+ MLX** on arm64 (that package needs macOS 14+) | — (Vulkan delegate needs the Vulkan SDK toolchain on the Windows runners) | `-gpu` (x86_64, static): **Vulkan** delegate | `-gpu` (arm64-v8a + x86_64, multi-ABI static bundle): **Vulkan** delegate | `-gpu` xcframework: **CoreML + MPS** delegates |
| **LiteRT** | `-gpu` (arm64, shared): upstream's prebuilt **Metal accelerator** | `-gpu` (x86_64, shared): prebuilt **WebGPU accelerator** (D3D12) | `-gpu` (x86_64 + aarch64, shared): prebuilt **WebGPU accelerator** (Vulkan) | `-gpu` (arm64-v8a + x86_64, multi-ABI shared bundle): prebuilt **OpenCL/OpenGL + WebGPU accelerators** | — (no prebuilt Metal accelerator for iOS yet) |
| **TFLite** | `-gpu` (x86_64 + arm64, shared + static): **Metal GPU delegate** (experimental: upstream tests it on iOS only) | — | — (desktop OpenCL delegate unsupported upstream) | `-gpu` (arm64-v8a + x86_64, multi-ABI shared + static bundles): official **OpenCL GPU delegate** (`TfLiteGpuDelegateV2*`) | `-gpu` xcframework: Google's official **Metal + CoreML** delegate xcframeworks |

Notes:

- **WebGPU ships its own Dawn (ONNX Runtime).** The `-gpu` ORT archives are the
  *external-Dawn* build anira v3 needs: ORT links only the `dawn_proc` thunks and the
  consumer hands it the proc table (`ep.webgpuexecutionprovider.dawnProcTable`) of the
  one Dawn in the process. That Dawn is in the same archive (`libwebgpu_dawn`, the
  `webgpu/` + `dawn/` headers, `DAWN_VERSION` = the revision ORT's `deps.txt` pins), so
  ORT, Dawn and the proc-table layout are one versioned triple. On Windows the archive
  also carries the shader compilers Dawn loads from beside the module (`dxcompiler.dll`,
  `dxil.dll`, `d3dcompiler_47.dll`). Details in [`engines/onnxruntime`](../engines/onnxruntime).
- **LiteRT's accelerators are dlopen'd**: the `-gpu` package is the CPU `libLiteRt` plus
  upstream's prebuilt accelerator library next to it; the runtime finds it via
  `kLiteRtEnvOptionTagRuntimeLibraryDir`. LiteRT's WebGPU accelerator embeds its own Dawn,
  which is fine because it is a separate shared object with its own symbol namespace.
- **ExecuTorch default packages changed**: CoreML/MLX used to be compiled into the
  default macOS packages ("wired in but off"); they now live in the `-gpu` variant
  only. The default macOS arm64 package no longer requires macOS 14+ (that floor came
  from MLX) — it is back to 12.0; only the arm64 `-gpu` package needs 14+.
- The ExecuTorch Vulkan delegate dlopens `libvulkan` via volk, so the Linux/Android
  `-gpu` packages add **no hard runtime dependency** — without a Vulkan driver or a
  vulkan-partitioned `.pte` they behave exactly like the CPU package. The build needs
  `glslc` (the LunarG shaderc release, fetched by `build-executorch.sh`).
- **TFLite Android GPU delegate**: upstream's CMake source list omits the Android-only
  async/EGL/AHardwareBuffer helpers `delegate.cc` needs; `engines/tflite/CMakeLists.txt`
  adds them and links EGL + GLESv3 (OpenCL and libandroid are dlopen'd by the delegate).
- Both **CUDA** channels are **CUDA 13** (libtorch `cu130`, ORT `gpu_cuda13`) + cuDNN 9,
  so one NVIDIA stack serves both `-cuda` packages. Blackwell/RTX-50 is covered; Turing
  (2018) is the oldest supported generation.
- No macOS **universal** `-gpu` archives (the universal lipo job aggregates by kind
  only); consumers pick the per-arch `-gpu` archive.

## How the smoke proves the accelerator

Every `-gpu` leg runs the forward pass **on the accelerator** on GPU-less hosted runners:

| Platform | Software GPU used by the smoke |
|---|---|
| Linux | Mesa **lavapipe** (software Vulkan; the smoke action installs it and sets `VK_ICD_FILENAMES`) — ORT WebGPU, LiteRT WebGPU. ExecuTorch Vulkan is a registry proof (the delegate is registered; the CPU `add.pte` still runs) |
| Windows | **WARP** (Microsoft's software D3D12 adapter) — ORT DirectML + WebGPU, LiteRT WebGPU |
| macOS | real **Metal** (the runners have a GPU) — ORT CoreML/WebGPU, libtorch MPS, ExecuTorch CoreML/MPS/MLX, LiteRT Metal, TFLite Metal |
| Android / iOS | link-level proof only (cross-compiled): the smoke references the delegate entry point / asks the backend registry, so a missing accelerator fails the link or the registry check; LiteRT Android runs its GPU compile on the emulator's software GL |

What each smoke asserts: ORT runs the pass once per EP the package ships (keyed on the
provider headers — `coreml_provider_factory.h`, `dml_provider_factory.h`,
`webgpu_provider_factory.h`); libtorch runs an op on the MPS device; ExecuTorch asks
`get_backend_class()` for every delegate the variant claims; LiteRT asserts
`LiteRtCompiledModelIsFullyAccelerated` after a GPU compile; TFLite creates the Metal/OpenCL
delegate and runs through it. The **default** packages assert the opposite (no EP header, no
delegate registered, GPU compile refused).

## How a variant leg works

- Preset `<engine>-<platform>-<arch>-{gpu|cuda}-<kind>` sets `BACKENDS_FLAVOR`
  (`coreml+webgpu` / `dml+webgpu` / `webgpu` / `mps` / `cuda` / `linux-cuda` /
  `windows-cuda` / `vulkan` / `gpu`); `vendor.anira.name` carries the `-gpu`/`-cuda` token
  so the archive is `<lib>-<version>-<Platform>-<arch>-<variant>-<kind>.zip`.
- `cmake/ExternalEngine.cmake` forwards the flavor to the engine's `stage.sh`, which routes
  it to the from-source build (`--use_coreml --use_dml --use_webgpu --use_external_dawn`,
  `USE_MPS=1`, `EXECUTORCH_BUILD_COREML/MPS/MLX/VULKAN=ON`, `TFLITE_BUILD_{METAL,GPU}_DELEGATE`)
  or the repackage script (CUDA prebuilts with NVIDIA-lib stripping, LiteRT prebuilt
  accelerators, the TFLite iOS delegate xcframeworks).
- Mobile: the Android bundle job takes `android_bundles` (`[{kind, variant}]`) and folds each
  ABI's whole `lib/` dir (accelerators included) into the multi-ABI archive; the iOS job takes
  `ios_variants` and builds one xcframework per variant.

## Consumer-facing notes (anira side)

- anira must expose **execution-provider / delegate selection** per backend; the variant
  packages are inert without it (they run CPU by default). anira v3's provider enum
  (`DEFAULT` / `CUDA` / `WEBGPU` / `DIRECTML` / `COREML` / `XNNPACK` / `VULKAN`) maps 1:1
  onto what the archives ship; `anira::webgpu_dawn` is the imported Dawn of the ORT `-gpu`
  package, and `ANIRA_ONNXRUNTIME_DAWN_VERSION` the revision anira's Machine asserts against.
- **Static macOS ORT `-gpu` consumers** must additionally link `CoreML.framework` (see the
  smoke CMakeLists for the exact link line); WebGPU consumers link the shipped
  `webgpu_dawn` library (`DAWN_NATIVE_SHARED_LIBRARY WGPU_SHARED_LIBRARY`, C++20 for the
  `webgpu_cpp.h` header).
- `-cuda` packages: user installs CUDA 13.x + cuDNN 9 and puts them on the library path.
  The ORT CUDA EP is loaded on demand (`libonnxruntime_providers_cuda`), so the base lib
  still runs CPU-only without them; libtorch `-cuda` links its CUDA glue directly, so it
  does NOT load at all without the NVIDIA libs.
- ExecuTorch delegates only run models **exported for that delegate** (`.pte` partitioned
  for CoreML/MPS/MLX/Vulkan) — needs matching export documentation/tooling.
- LiteRT `-gpu`: set `kLiteRtEnvOptionTagRuntimeLibraryDir` to the package's `lib/` (or ship
  the accelerator beside the app binary) and compile with `kLiteRtHwAcceleratorGpu`.

## Deliberately not offered, and why

- **ROCm** (Linux/AMD): narrow supported-GPU list, very large packages, rough install UX.
  AMD/Intel on Linux are served by the **WebGPU** (Vulkan) and ExecuTorch **Vulkan** paths.
- **TensorRT EP**: adds a TensorRT install + version-pinning burden; the CUDA EP covers
  the NVIDIA need (the repackage drops the TensorRT provider from upstream's gpu bundle).
- **OpenVINO EP** (Intel): niche for audio workstations; revisit on demand.
- **Vulkan on macOS**: Apple has no native Vulkan — it would run through MoltenVK, where
  the native CoreML/MPS/Metal paths are faster and better supported.
- **TFLite desktop OpenCL delegate** (Linux/Windows): unsupported upstream; LiteRT's
  WebGPU accelerator is the desktop path for that runtime.
- **Linux aarch64 GPU** beyond LiteRT WebGPU: effectively means NVIDIA Jetson/Grace; niche.

## Open items

- **ONNX Runtime Android `-gpu`** (WebGPU EP over an NDK cross-built Dawn).
- **LiteRT iOS `-gpu`** (Metal accelerator xcframework; upstream ships none prebuilt).
- **ExecuTorch Windows `-gpu`** (Vulkan delegate; needs the Vulkan SDK on the runner).
- macOS **universal** `-gpu` archives.
