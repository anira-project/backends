# anira-backends

Prebuilt inference-engine binaries for [anira](https://github.com/anira-project/anira).
Each backend is built from source (or repackaged from an upstream prebuilt) and
published as GitHub release archives that anira's CMake downloads at configure time.

## Backends

| Backend     | Upstream                                                          | lib name           | License    |
| ----------- | ----------------------------------------------------------------- | ------------------ | ---------- |
| LiteRT      | [google-ai-edge/LiteRT](https://github.com/google-ai-edge/LiteRT) | `tensorflowlite_c` | Apache-2.0 |
| ONNXRuntime | [microsoft/onnxruntime](https://github.com/microsoft/onnxruntime) | `onnxruntime`      | MIT        |
| LibTorch    | [pytorch/pytorch](https://github.com/pytorch/pytorch)             | `torch`            | BSD-3      |

This repo is licensed [Apache-2.0](./LICENSE); the **published binaries** follow their
upstream licenses (above).

## Support matrix

What ships per target — `shared` (dynamic lib) and/or `static` (one merged, drop-in archive):

| Target                          | LiteRT            | ONNXRuntime       | LibTorch |
| ------------------------------- | ----------------- | ----------------- | -------- |
| macOS x86_64                    | shared · static   | shared · static   | shared   |
| macOS arm64                     | shared · static   | shared · static   | shared   |
| macOS universal                 | shared · static   | shared · static   | shared   |
| Linux x86_64                    | shared · static   | shared · static   | shared   |
| Linux aarch64                   | shared · static   | shared · static   | shared   |
| Windows x86_64                  | shared · static ¹ | shared · static ¹ | shared   |
| Windows arm64                   | shared · static ¹ | shared · static ¹ | shared   |
| Android (`arm64-v8a` + `x86_64`)| shared · static   | shared · static   | —        |
| iOS (xcframework)               | static            | static            | —        |

> ¹ Windows `static` also ships a `Debug` variant.
> `—` = not provided (LibTorch is desktop-shared only).

## Releases

Backends are versioned independently but **released together, keyed to the anira
version**: tag `v2.0.3` builds every backend at its pinned `engines/<backend>/VERSION`
and publishes all archives to a single release `v2.0.3`.

## Sponsor
<img src="https://raw.githubusercontent.com/anira-project/anira/main/docs/img/bmftr-funding.png" alt="Funded by the German Federal Ministry of Research, Technology and Space (BMFTR)" width="200">
