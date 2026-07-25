# GPU support

Status: **implemented on this branch** (Phases 1–4 below; each leg needs its first CI
round to converge, like every from-source recipe in this repo).

## Principles

1. **CPU-only users get CPU-only packages.** GPU support is ALWAYS a separate variant
   archive (`-gpu` / `-cuda` name token) — never baked into the default packages. At
   typical audio buffer sizes, host↔device transfer latency and scheduling jitter
   usually make CPU inference faster and more predictable anyway; GPU variants target
   large models / relaxed-latency use cases.
2. **A variant is one extra build leg, not a new pipeline.** The accelerator is encoded
   in the preset's `vendor.anira.name` (e.g. `Windows-x86_64-gpu`), so archive naming,
   packaging, upload, smoke and publish all reuse the existing machinery. The preset's
   `BACKENDS_FLAVOR` cache var tells the engine's `stage.sh` what to build.
3. **CUDA runtime + cuDNN are user-provided prerequisites**, documented per package —
   bundling them would push archives past GitHub's 2 GB release-file limit and multiply
   download size. `-cuda` packages need the NVIDIA libraries on the library path at
   runtime (and therefore skip the CI smoke: `canRun=0` where the dynamic loader would
   fail without them).

## Variant matrix

| Backend | macOS | Windows | Linux |
|---|---|---|---|
| **ONNX Runtime** | `-gpu`: **CoreML EP** (GPU/ANE), x86_64 + arm64, static + shared, from source (`--use_coreml`) | `-gpu`: **DirectML EP**, x64 + arm64, shared, from source (`--use_dml`; Microsoft stopped publishing the DirectML NuGet after 1.24.4) · `-cuda`: **CUDA EP**, x64, shared, repackaged upstream `-gpu` prebuilt | `-cuda`: **CUDA EP**, x64, shared, repackaged upstream `-gpu` prebuilt |
| **LibTorch** | `-gpu`: **MPS**, arm64 only, shared, from source (`USE_MPS=1`) | `-cuda`: x64, shared, repackaged upstream `cu126` prebuilt, NVIDIA redist libs stripped | `-cuda`: x64, shared, repackaged upstream `cu126` prebuilt, NVIDIA redist libs stripped |
| **ExecuTorch** | `-gpu`: **CoreML delegate** (+ **MLX** on arm64), static, from source | — (Vulkan deferred: needs the Vulkan SDK toolchain on Windows runners) | `-gpu`: **Vulkan delegate** (experimental), x64, static, from source |
| **TFLite / LiteRT** | — | — | — (GPU delegate is mobile-only upstream) |

Notes:

- **ExecuTorch default packages changed**: CoreML/MLX used to be compiled into the
  default macOS packages ("wired in but off"); they now live in the `-gpu` variant
  only. Side effect: the default macOS arm64 package no longer requires macOS 14+
  (that floor came from MLX) — it is back to 12.0; only the arm64 `-gpu` package
  needs 14+.
- The ExecuTorch Vulkan delegate dlopens `libvulkan` via volk, so the Linux `-gpu`
  package adds **no hard runtime dependency** — without a Vulkan driver or a
  vulkan-partitioned `.pte` it behaves exactly like the CPU package. Build needs
  `glslc` on the runner (apt: `glslc`).
- libtorch CUDA channel is **cu126** (CUDA 12.6 + cuDNN 9) — the same CUDA 12.x
  generation ONNX Runtime 1.26 targets, so one NVIDIA stack serves both `-cuda`
  packages. (2.12.0 prebuilts exist for cu126 and cu130; cu128 was not published.)
- No macOS **universal** `-gpu` archives yet (the universal lipo job aggregates by
  kind only); consumers pick the per-arch `-gpu` archive.

Deliberately **not** offered, and why:

- **ROCm** (Linux/AMD): narrow supported-GPU list, very large packages, rough install UX.
- **TensorRT EP**: adds a TensorRT install + version-pinning burden; the CUDA EP covers
  the NVIDIA need (the repackage drops the TensorRT provider from upstream's gpu bundle).
- **OpenVINO EP** (Intel): niche for audio workstations; revisit on demand.
- **Vulkan on macOS**: Apple has no native Vulkan — it would run through MoltenVK, where
  the native CoreML/MPS paths are faster and better supported.
- **TFLite/LiteRT desktop GPU delegate**: unsupported upstream on desktop. Revisit with
  the Android/iOS GPU legs.
- **Linux aarch64 GPU**: effectively means NVIDIA Jetson/Grace; niche — separate request.

The known gap: **AMD/Intel GPUs on Linux** have no path until the ExecuTorch Vulkan
delegate (or a future ORT WebGPU EP leg) matures.

## How a variant leg works

- Preset `<engine>-<platform>-<arch>-{gpu|cuda}-<kind>` sets
  `BACKENDS_FLAVOR` (`coreml` / `dml` / `mps` / `cuda` / `linux-cuda` / `windows-cuda` /
  `vulkan`); `vendor.anira.name` carries the `-gpu`/`-cuda` token so the archive is
  `<lib>-<version>-<Platform>-<arch>-<variant>-<kind>.zip`.
- `cmake/ExternalEngine.cmake` forwards the flavor to the engine's `stage.sh`, which
  routes it to the from-source build (`--use_coreml`, `--use_dml`, `USE_MPS=1`,
  `EXECUTORCH_BUILD_COREML/MLX/VULKAN=ON`) or the repackage script (CUDA prebuilts,
  NVIDIA-lib stripping).
- The smoke proves the accelerator, not just the build: ORT runs the forward pass again
  with the variant's EP appended (CoreML on macOS `-gpu`; DirectML on Windows `-gpu`,
  which works on GPU-less runners via the WARP software adapter); libtorch `-gpu` runs
  an op on the Metal device — and the **default** packages assert the accelerator is
  absent. ORT packages advertise their EP via the provider header they ship
  (`coreml_provider_factory.h` / `dml_provider_factory.h`) — the same detection anira
  should use.

## Consumer-facing notes (anira side)

- anira must expose **execution-provider / delegate selection** per backend; the
  variant packages are inert without it (they run CPU by default).
- **Static macOS ORT `-gpu` consumers** must additionally link `CoreML.framework`
  (see the smoke CMakeLists for the exact link line).
- `-cuda` packages: user installs CUDA 12.x + cuDNN 9 and puts them on the library
  path. The ORT CUDA EP is loaded on demand (`libonnxruntime_providers_cuda`), so the
  base lib still runs CPU-only without them; libtorch `-cuda` links its CUDA glue
  directly, so it does NOT load at all without the NVIDIA libs.
- ExecuTorch delegates only run models **exported for that delegate** (`.pte`
  partitioned for CoreML/MLX/Vulkan) — needs matching export documentation/tooling.
