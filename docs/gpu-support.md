# GPU support — proposal (first draft)

Status: **draft / RFC**. Phase 1 is implemented on this branch; later phases are planned.

## Goals

Offer GPU acceleration per backend where the upstream runtime has a *supported* desktop
GPU path, without regressing the CPU packages that real-time audio users rely on:

1. **GPU is opt-in, CPU stays the default.** At typical audio buffer sizes, host↔device
   transfer latency and scheduling jitter usually make CPU inference faster and more
   predictable. GPU legs target large models / relaxed-latency use cases.
2. **Apple GPU support is baked into the existing packages** (CoreML EP, MPS): near-zero
   size cost, zero external dependencies — no separate archive needed.
3. **CUDA/DirectML ship as separate `-gpu`/`-cuda` archives, shared-only.** The ORT CUDA
   EP loads as a separate provider shim and cuDNN cannot realistically be linked
   statically; a variant archive keeps the base packages lean.
4. **CUDA runtime + cuDNN are user-provided prerequisites**, documented per package —
   bundling them would push LibTorch archives past GitHub's 2 GB release-file limit and
   multiply download size for everyone.

## Support matrix (proposed)

| Backend | macOS (arm64 / x86_64) | Windows (x64 / arm64) | Linux (x64 / aarch64) |
|---|---|---|---|
| **ONNX Runtime** | **CoreML EP** (GPU/ANE), both arches, baked into existing packages | **DirectML EP**, both arches, vendor-agnostic, `-gpu` variant | **CUDA EP**, x64 only, `-cuda` variant; aarch64 stays CPU |
| **LibTorch** | **MPS**, arm64 only (from-source build flips `USE_MPS=1`) | **CUDA**, x64 only, repackaged upstream; arm64 stays CPU | **CUDA**, x64 only, repackaged upstream; aarch64 stays CPU |
| **ExecuTorch** | **CoreML + MPS delegates** — already wired in the build, flip on | **Vulkan delegate**, x64 first, experimental | **Vulkan delegate**, x64 first, experimental |
| **TFLite / LiteRT** | — (GPU delegate is mobile-only upstream) | — | — |

Deliberately **not** offered, and why:

- **ROCm** (Linux/AMD): narrow supported-GPU list, very large packages, rough install UX.
- **TensorRT EP**: adds a TensorRT install + version-pinning burden; the CUDA EP covers
  the NVIDIA need.
- **OpenVINO EP** (Intel): niche for audio workstations; revisit on demand.
- **Vulkan on macOS**: Apple has no native Vulkan — it would run through MoltenVK, where
  the native CoreML/MPS paths are faster and better supported.
- **TFLite/LiteRT desktop GPU delegate**: unsupported upstream on desktop (OpenCL/GL/
  Metal, mobile-focused). Revisit with the Android/iOS GPU legs.
- **Linux aarch64 GPU**: effectively means NVIDIA Jetson/Grace (CUDA sbsa); niche —
  treat as a separate request.

The known gap this leaves: **AMD/Intel GPUs on Linux** have no path until the
ExecuTorch Vulkan delegate (or a future ORT WebGPU EP leg) matures.

## Rollout phases

| Phase | Deliverable | Effort / risk |
|---|---|---|
| **1 (this branch)** | ORT **CoreML EP** compiled into the existing macOS static+shared packages; LibTorch **MPS** enabled in the from-source macOS arm64 build. Smoke tests exercise both. | Low — config flags on existing builds |
| 2 | ORT **DirectML** `-gpu` variant, Windows x64 + arm64 (shared) | Low-medium — well-trodden upstream path; DirectML.dll redist ships in the archive |
| 3 | ORT **CUDA EP** + LibTorch **CUDA** repackage, Linux/Windows x64, `-cuda` variants (shared-only) | Medium — archive size/splitting; CI builds without a GPU, smoke needs a GPU runner or init-only check |
| 4 | ExecuTorch **Vulkan delegate** Linux/Windows x64 (experimental tier) + CoreML/MPS delegates on | High — desktop Vulkan delegate is uncharted upstream; needs an export-side (`.pte` partitioning) story |

## Consumer-facing notes (anira side)

- anira must expose **execution-provider / delegate selection** in its backend config
  (e.g. a per-backend accelerator preference) before Phase 2+ is usable; Phase 1 EPs are
  opt-in at session level and change nothing for existing CPU users.
- **Static macOS ORT consumers** must now additionally link `CoreML.framework`
  (the smoke test documents the exact link line).
- ExecuTorch delegates only run models **exported for that delegate** — Phase 4 needs
  matching export documentation/tooling.

## Per-phase packaging

- Phase 1: no new archives, no renames. macOS packages simply gain the EP/backend.
- Phase 2/3: new `onnxruntime-*-gpu` (DirectML) and `onnxruntime-*-cuda` /
  `libtorch-*-cuda` archives, shared-only, same staging layout as the existing ones.
- Phase 4: ExecuTorch delegates land in the existing static package (delegates are
  compiled in; inactive unless the `.pte` targets them).
