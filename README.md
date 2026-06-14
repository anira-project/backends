# anira-backends

Prebuilt inference-engine binaries for [anira](https://github.com/anira-project/anira).
Each backend is built from source (or repackaged from an upstream prebuilt) and
published as GitHub release archives that anira's CMake downloads at configure time.

## Backends

| Backend     | C API        | Upstream                                                          | lib name           | License    |
| ----------- | ------------ | ----------------------------------------------------------------- | ------------------ | ---------- |
| TFLite      | `TfLite*`    | [tensorflow/lite](https://github.com/tensorflow/tensorflow/tree/master/tensorflow/lite/c) | `tensorflowlite_c` | Apache-2.0 |
| LiteRT      | `LiteRt*` ²  | [google-ai-edge/LiteRT](https://github.com/google-ai-edge/LiteRT) | `LiteRt`           | Apache-2.0 |
| ONNXRuntime | —            | [microsoft/onnxruntime](https://github.com/microsoft/onnxruntime) | `onnxruntime`      | MIT        |
| LibTorch    | —            | [pytorch/pytorch](https://github.com/pytorch/pytorch)             | `torch`            | BSD-3      |

TFLite and LiteRT are **two C APIs for the same runtime** (LiteRT is the rebranded TensorFlow
Lite): `TfLite*` is the mature legacy API; `LiteRt*` is LiteRT's newer native API. Pick one.

This repo is licensed [Apache-2.0](./LICENSE); the **published binaries** follow their
upstream licenses (above).

## Support matrix

What ships per target — `shared` and/or `static`:

| Target                          | TFLite            | LiteRT ²            | ONNXRuntime       | LibTorch |
| ------------------------------- | ----------------- | ------------------- | ----------------- | -------- |
| macOS x86_64                    | shared · static   | shared · static     | shared · static   | shared   |
| macOS arm64                     | shared · static   | shared · static     | shared · static   | shared   |
| macOS universal                 | shared · static   | shared · static     | shared · static   | shared   |
| Linux x86_64                    | shared · static   | shared · static     | shared · static   | shared   |
| Linux aarch64                   | shared · static   | shared · static     | shared · static   | shared   |
| Windows x86_64                  | shared · static ¹ | shared · static ¹   | shared · static ¹ | shared   |
| Windows arm64                   | shared · static ¹ | shared · static ¹ ³ | shared · static ¹ | shared   |
| Android (`arm64-v8a` + `x86_64`)| shared · static   | shared · static ⁴   | shared · static   | —        |
| iOS (xcframework)               | static            | shared              | static            | —        |

macOS `shared` dylibs are **Developer ID code-signed** (Hardened Runtime, timestamped); the
consuming app re-signs/notarizes on embed.

> ¹ Windows `static` also ships a `Debug` variant.

> ² LiteRT ships the **native `LiteRt*` C API** (`libLiteRt`) — distinct from the `tflite` engine's
> legacy `TfLite*` API. `shared` is repackaged from official prebuilts (`litert/prebuilt/`, pinned to
> a main SHA) plus from-source Bazel where none ship (macOS x86_64, Windows-arm64). `static` is built
> from source (no static lib ships upstream) and merged into one archive. Only iOS `static` isn't
> provided (iOS ships the prebuilt xcframework).

> ³ Windows-arm64 has no upstream prebuilt — both `shared` (`libLiteRt.dll`) and `static` are built
> from source with **clang-cl** + LLVM 20 (MSVC `cl` can't compile the deps' GCC/clang constructs),
> **without XNNPACK** (its pinned Bazel build has no arm64-Windows microkernels) — CPU via ruy/builtin.

> ⁴ Android `static` is built from source inside LiteRT's public `ml-build` container (which provides
> the `cuda_redist`/`rules_ml_toolchain` externals a bare runner lacks), then merged per-ABI.

> `—` = not provided.

## Releases

Backends are versioned independently but **released together, keyed to the anira
version**: tag `v2.0.3` builds every backend at its pinned `engines/<backend>/VERSION`
and publishes all archives to a single release `v2.0.3`.

## Sponsor
<img src="https://raw.githubusercontent.com/anira-project/anira/main/docs/img/bmftr-funding.png" alt="Funded by the German Federal Ministry of Research, Technology and Space (BMFTR)" width="200">
