# Licensing

## This repository

The build scripts, CMake, and CI in this repo are licensed under
**Apache-2.0** — see [`LICENSE`](./LICENSE).

## Produced binaries

The binaries published in the GitHub releases are **built from (or repackaged from)
upstream projects** and are governed by **their** licenses, not this repo's. Each
backend's primary upstream license:

| Backend     | Upstream | License | Link |
| ----------- | -------- | ------- | ---- |
| LiteRT      | [google-ai-edge/LiteRT](https://github.com/google-ai-edge/LiteRT) / [tensorflow](https://github.com/tensorflow/tensorflow) | Apache-2.0 | [LICENSE](https://github.com/tensorflow/tensorflow/blob/master/LICENSE) |
| ONNXRuntime | [microsoft/onnxruntime](https://github.com/microsoft/onnxruntime) | MIT | [LICENSE](https://github.com/microsoft/onnxruntime/blob/main/LICENSE) |
| LibTorch    | [pytorch/pytorch](https://github.com/pytorch/pytorch) | BSD-3-Clause | [LICENSE](https://github.com/pytorch/pytorch/blob/main/LICENSE) |

> Note: a built backend statically bundles several third-party dependencies (e.g. for
> LiteRT: XNNPACK, Abseil, ruy, FlatBuffers, FarmHash, FFT2D, cpuinfo, …), each under its
> own license. The links above are the primary project licenses; consult the upstream
> repositories' `third_party/` / `LICENSE` files for the full dependency licensing. The
> prebuilt iOS `TensorFlowLiteC.xcframework` additionally ships a `PrivacyInfo.xcprivacy`
> manifest.
