# anira-backends

Prebuilt inference-engine binaries for [anira](https://github.com/anira-project/anira).
Each backend is built from source (or repackaged from an upstream prebuilt) and
published as GitHub release archives that anira's CMake downloads at configure time.

## Backends

| Backend     | C API        | Upstream                                                          | lib name           | License    |
| ----------- | ------------ | ----------------------------------------------------------------- | ------------------ | ---------- |
| TFLite      | `TfLite*`    | [tensorflow/lite](https://github.com/tensorflow/tensorflow/tree/master/tensorflow/lite/c) | `tensorflowlite_c` | Apache-2.0 |
| LiteRT      | `LiteRt*`    | [google-ai-edge/LiteRT](https://github.com/google-ai-edge/LiteRT) | `LiteRt`           | Apache-2.0 |
| ONNXRuntime | —            | [microsoft/onnxruntime](https://github.com/microsoft/onnxruntime) | `onnxruntime`      | MIT        |
| LibTorch    | —            | [pytorch/pytorch](https://github.com/pytorch/pytorch)             | `torch`            | BSD-3      |
| ExecuTorch  | —            | [pytorch/executorch](https://github.com/pytorch/executorch)       | `executorch`       | BSD-3      |

TFLite and LiteRT are **two C APIs for the same runtime** (LiteRT is the rebranded TensorFlow
Lite): `TfLite*` is the mature legacy API; `LiteRt*` is LiteRT's newer native API. Pick one.

LibTorch and ExecuTorch are **two PyTorch C++ runtimes**: LibTorch is the full desktop runtime;
ExecuTorch is the on-device runtime that runs ahead-of-time-exported `.pte` models. We ship a
**generic** ExecuTorch (full CPU op set + XNNPACK, not a per-model selective build), so one
package loads any `.pte`. Both are consumed via `find_package` (`Torch` / `executorch`).

This repo is licensed [Apache-2.0](./LICENSE); the **published binaries** follow their
upstream licenses (above).

## Support matrix

What ships per target — `shared` and/or `static`:

| Target                          | TFLite            | LiteRT              | ONNXRuntime       | LibTorch | ExecuTorch |
| ------------------------------- | ----------------- | ------------------- | ----------------- | -------- | ---------- |
| macOS x86_64                    | shared · static   | shared · static     | shared · static   | shared   | static     |
| macOS arm64                     | shared · static   | shared · static     | shared · static   | shared   | static     |
| macOS universal                 | shared · static   | shared · static     | shared · static   | shared   | static     |
| Linux x86_64                    | shared · static   | shared · static     | shared · static   | shared   | static     |
| Linux aarch64                   | shared · static   | shared · static     | shared · static   | shared   | static     |
| Windows x86_64                  | shared · static ¹ | shared · static ¹   | shared · static ¹ | shared   | static     |
| Windows arm64                   | shared · static ¹ | shared · static ¹   | shared · static ¹ | shared   | static     |
| Android (`arm64-v8a` + `x86_64`)| shared · static   | shared · static     | shared · static   | —        | —          |
| iOS (xcframework)               | static            | static              | static            | —        | —          |
| WASM (Emscripten)               | —                 | —                   | static ²          | —        | —          |

macOS `shared` dylibs are **Developer ID code-signed** (Hardened Runtime, timestamped); the
consuming app re-signs/notarizes on embed.

> ¹ Windows `static` also ships a `Debug` variant.

> ² Emscripten static archive — build flags and consumer requirements in
> [`engines/onnxruntime`](./engines/onnxruntime).

> ExecuTorch is **static-only, built from source on every leg** (no upstream prebuilt desktop
> runtime), **CPU-only by default** (XNNPACK + optimized kernels everywhere). GPU delegates
> live in the separate `-gpu` variants: CoreML (+MLX on arm64) on macOS, Vulkan on Linux x64
> (experimental) — see [`docs/gpu-support.md`](./docs/gpu-support.md). Windows Vulkan and
> Android/iOS GPU are deliberate follow-ups.

> `—` = not provided.

Per-backend build details (e.g. LiteRT's `LiteRt*` vs `TfLite*` API split, Windows-arm64
from-source toolchain, Android `static`) live in each engine's README under
[`engines/<backend>/`](./engines).

GPU acceleration ships as **separate `-gpu` / `-cuda` variant archives** — the default
packages above stay CPU-only. Variants: ONNXRuntime CoreML (macOS), DirectML (Windows),
CUDA (Linux/Windows x64); LibTorch MPS (macOS arm64), CUDA (Linux/Windows x64);
ExecuTorch CoreML+MLX (macOS), Vulkan (Linux x64, experimental). Details in
[`docs/gpu-support.md`](./docs/gpu-support.md).

## Releases

Backends are versioned independently but **released together, keyed to the anira
version**: tag `v2.1.1` builds every backend at its pinned `engines/<backend>/VERSION`
and publishes all archives to a single release `v2.1.1`.

## Sponsor
<img src="https://raw.githubusercontent.com/anira-project/anira/main/docs/img/bmftr-funding.png" alt="Funded by the German Federal Ministry of Research, Technology and Space (BMFTR)" width="200">
