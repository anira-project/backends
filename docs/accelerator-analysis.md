# Accelerator analysis — every option anira users might want

Status: analysis / decision input (2026-07). Companion to [`gpu-support.md`](./gpu-support.md),
which documents what already ships. This document surveys the WHOLE option space —
CUDA, OpenVINO, CoreML, Linux GPU, NPUs, mobile — across all four runtimes, and ranks
what to build next.

## 1. Who actually wants what

| User segment | Typical model | What they need | Accelerator that serves it |
|---|---|---|---|
| Real-time plugin devs (small models, ≤10 ms budgets) | RNN/TCN, <10 MB | lowest latency, zero jitter | **CPU** — transfers + scheduling make GPUs *slower* here; this stays the default |
| Big-model users (neural amps/synthesis, diffusion, source separation) | 100 MB–2 GB | throughput; latency secondary | CUDA, CoreML/MPS, DirectML |
| Laptop users caring about battery/thermals | any | sustained low-power inference | **NPU** (Apple ANE, Qualcomm Hexagon, Intel NPU) |
| Linux studio machines (often AMD/Intel GPUs) | any | *any* GPU path at all | the "DirectML alternative on Linux" problem (§5) |
| Mobile app devs (iOS/Android) | small–medium | on-device GPU/NPU, small binaries | CoreML/Metal, GPU delegates, QNN |

## 2. CUDA (NVIDIA)

| Backend | Upstream support | Our status | Notes |
|---|---|---|---|
| ONNX Runtime | CUDA EP, official prebuilts | **✅ shipped** (`-cuda`, Linux/Win x64) | provider dlopen'd on demand → CPU fallback without CUDA installed |
| LibTorch | official cu126/cu130 prebuilts | **✅ shipped** (`-cuda`, cu126, NVIDIA libs stripped) | hard-links CUDA → won't load without user's CUDA+cuDNN |
| ExecuTorch | CUDA backend (AOTInductor-based) — **experimental, new** | ○ not shipped | desktop CUDA on an on-device runtime is upstream-immature; wait |
| TFLite / LiteRT | none | — | upstream has no desktop CUDA story |

**Verdict**: done where it matters. ExecuTorch-CUDA only if a user demands one runtime
across desktop-NVIDIA and mobile. TensorRT stays rejected (session-creation engine
compilation = seconds-to-minutes plugin load; version-locked install; CUDA EP suffices —
escape hatch: the upstream archive we repackage contains the TensorRT provider, one
repackage flag away).

## 3. OpenVINO (Intel CPU / iGPU / dGPU / NPU)

The picture changed in 2025/26 — Intel now maintains THREE first-party integrations:

| Backend | Upstream support | Effort for us | Notes |
|---|---|---|---|
| ONNX Runtime | OpenVINO EP (mature, years old) | medium: from-source build + bundle OpenVINO runtime (~200–400 MB) | no upstream C-archive prebuilt to repackage |
| ExecuTorch | **official OpenVINO backend** (preview 2025.1 → hundreds of upstream op tests by 2026; CPU/iGPU/dGPU/NPU) | medium: `EXECUTORCH_BUILD_OPENVINO` + OpenVINO dep; fits our from-source model | the strategically interesting one — same runtime covers Intel NPU *and* GPU |
| TFLite / LiteRT | **LiteRT-Next Intel NPU plugin** (OpenVINO compiler plugin, AOT-compiles subgraphs) | high: requires the new LiteRT `CompiledModel` API, not the classic C APIs we ship | early; export-side AOT step per model |
| LibTorch | none for C++ (torch.compile-openvino is Python-only) | — | not applicable |

**Verdict**: the *demand* signal is Intel AI-PC laptops (Core Ultra NPU) — battery-friendly
sustained inference, a genuinely good fit for audio. But every path needs the OpenVINO
runtime redistributed (~hundreds of MB) and models behave best re-exported. Recommend:
**wait for one concrete user ask**, then do ExecuTorch-OpenVINO first (cleanest upstream
integration, one dep covers GPU+NPU), ORT-OpenVINO second. Slot both under the `-npu`
token (their headline value is the NPU).

## 4. CoreML / Apple (GPU + ANE)

| Backend | Upstream support | Our status |
|---|---|---|
| ONNX Runtime | CoreML EP | **✅ shipped** on macOS (`-gpu`, static+shared, both arches); ○ iOS xcframework — same `--use_coreml` flag, straightforward follow-up |
| LibTorch | no CoreML; **MPS** is the Apple path | **✅ shipped** (`-gpu`, arm64) — MPS is GPU-only, no ANE; that's upstream's design |
| ExecuTorch | CoreML delegate (+ MPS delegate, + MLX arm64) | **✅ shipped** on macOS (`-gpu`); iOS xcframework already embeds CoreML+MPS — ○ split into cpu / `-gpu` variants for consistency with the everything-is-a-variant rule |
| TFLite / LiteRT | classic CoreML delegate (iOS; maintenance-mode upstream) | ○ low priority — Metal GPU delegate is the healthier Apple path there (§7) |

**Verdict**: Apple is our most complete story. Remaining work is mobile packaging
(ORT iOS `-gpu` xcframework; ExecuTorch iOS variant split), not capability.

## 5. The "DirectML alternative on Linux" problem

There is **no Linux equivalent of DirectML** — no vendor-neutral, driver-stable,
officially-supported ML API. Candidates:

| Candidate | Coverage | State | Assessment |
|---|---|---|---|
| **ExecuTorch Vulkan delegate** | NVIDIA/AMD/Intel via Vulkan drivers | **✅ shipped** (`-gpu`, experimental) | today's only vendor-neutral Linux GPU answer in our matrix; mobile-tuned kernels, needs `.pte` exported for Vulkan |
| **ORT WebGPU EP** (Dawn → Vulkan) | all vendors | native EP exists; manylinux wheels since 2026-04; still maturing | **the strategic bet** — one EP also covers Windows (D3D12) and macOS (Metal); revisit ~1.28+: build `--use_webgpu`, benchmark vs CPU on an audio model, ship as experimental `-gpu` Linux leg if it wins |
| ROCm / MIGraphX (AMD) | narrow AMD list | mature-ish | rejected: tens-of-GB user install, narrow HW list, Linux-only |
| OpenVINO (Intel GPUs only) | Intel only | mature | not vendor-neutral; covered under §3 |
| OpenCL / SYCL | — | no runtime we ship supports it | dead end |

**Verdict**: short term, Linux AMD/Intel GPU users stay on CPU (defensible: real-time
audio favors CPU anyway). Medium term, **ORT WebGPU EP is the answer** — track it and
prototype when we bump ORT.

## 6. NPU support

| NPU | Reached via | Platforms | Effort | Priority |
|---|---|---|---|---|
| **Apple ANE** | CoreML EP / CoreML delegate | macOS/iOS | **already shipped** (inside our `-gpu` CoreML packages) | done |
| **Qualcomm Hexagon** | ORT **QNN EP** — official NuGet (win-arm64, Qualcomm libs bundled+redistributable) + Android AAR | win-arm64, Android | **low — pure repackage**, same pipeline as `-cuda`; CI-smokeable via QnnCpu backend, HTP needs quantized models | **#1 next thing to build** — Snapdragon X laptops ARE the win-arm64 audience |
| | ExecuTorch QNN backend | Android | medium (needs QNN SDK at build) | later, if ExecuTorch-on-Android users ask |
| | LiteRT-Next Qualcomm plugin | Android | high (new API surface) | watch |
| **Intel NPU** | ORT OpenVINO EP / ExecuTorch OpenVINO backend / LiteRT-Next Intel plugin | win/linux x64 | medium–high (§3) | on demand |
| **AMD XDNA (Ryzen AI)** | ORT VitisAI EP | win x64 | early upstream, weak packaging | too early |
| **MediaTek / others** | ExecuTorch & LiteRT vendor backends | Android | per-vendor SDK zoo | out of scope |

Naming: all of these take the **`-npu`** token — one archive per backend×platform, the
vendor chosen by what the platform actually has (win-arm64→QNN, x86→OpenVINO-if-built).

## 7. Mobile support

| Backend | iOS today | Android today | Mobile accelerator roadmap |
|---|---|---|---|
| ONNX Runtime | static xcframework (CPU) | shared AAR-repackage + static (CPU) | ○ iOS `-gpu` CoreML (easy); ○ Android `-npu` QNN (repackage); Android GPU: NNAPI is deprecated by Google — skip |
| TFLite / LiteRT | static xcframework (CPU) | shared+static (CPU) | ○ `-gpu` GPU delegate — **the** canonical mobile GPU path (OpenCL/GL Android, Metal iOS); ○ `-npu` LiteRT-Next later |
| ExecuTorch | xcframework **already incl. CoreML+MPS** | static per-ABI (CPU) | ○ iOS: split cpu/`-gpu` variants; ○ Android `-gpu` Vulkan (the delegate we already build on Linux) |
| LibTorch | — | — | upstream answer for mobile IS ExecuTorch; keep LibTorch desktop-only |

**Verdict**: mobile GPU is where users will feel the difference most (mobile CPUs
throttle). Order: LiteRT GPU delegate (most-used mobile runtime) → ORT iOS CoreML →
ExecuTorch Android Vulkan → QNN Android.

## 8. Recommended build order (effort × demand)

| # | Item | Token | Effort | Why now |
|---|---|---|---|---|
| 1 | ORT **QNN** win-arm64 | `-npu` | **low** (repackage) | Snapdragon laptops; zero user deps; CI-smokeable |
| 2 | ORT **CoreML iOS** xcframework | `-gpu` | low (existing flag) | completes the Apple story |
| 3 | LiteRT/TFLite **GPU delegate** iOS+Android | `-gpu` | medium | canonical mobile GPU, biggest mobile win |
| 4 | ExecuTorch **Vulkan on Android** (+ iOS variant split) | `-gpu` | medium (delegate already builds) | reuses shipped work |
| 5 | ORT **QNN Android** | `-npu` | low-medium (AAR repackage) | pairs with #1 |
| 6 | ExecuTorch **Windows Vulkan** | `-gpu` | medium (Vulkan SDK on runner) | closes a matrix hole |
| 7 | ORT **WebGPU EP** Linux (prototype → experimental leg) | `-gpu` | medium, gated on upstream | the only real Linux AMD/Intel answer |
| 8 | **OpenVINO** (ExecuTorch backend first, then ORT EP) | `-npu` | medium-high | on first concrete Intel-NPU user ask |

Standing rejections (unchanged, with reasons in §2–§6): TensorRT, ROCm/MIGraphX,
VitisAI (for now), NNAPI, MoltenVK-Vulkan-on-macOS, TFLite desktop GPU.

## 9. Cross-cutting requirements

- Every item above ships as a **variant archive** (`-gpu`/`-cuda`/`-npu`), never in the
  CPU default; smokes must prove the accelerator present in variants and absent in
  defaults (the guards that caught round 1).
- **anira API**: one `Accelerator` enum (`cpu | gpu | cuda | npu`) mapped per backend —
  the archive token and the enum value must correspond one-to-one.
- **Export-side story**: ExecuTorch delegates, QNN-HTP, LiteRT-Next NPU and OpenVINO all
  work best (or only) with models exported/quantized for them — each shipped variant
  needs a documented export recipe, or users will file "it's not faster" bugs.
