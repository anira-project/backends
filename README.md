# anira-backends

Prebuilt inference-engine binaries for [anira](https://github.com/anira-project/anira).
Each backend is built from source (or repackaged from an upstream prebuilt) and
published as GitHub release archives that anira's CMake downloads at configure time.

## Backends

| Backend     | Status            | Upstream                                                                                | lib name           |
| ----------- | ----------------- | --------------------------------------------------------------------------------------- | ------------------ |
| LiteRT      | Active            | [google-ai-edge/LiteRT](https://github.com/google-ai-edge/LiteRT)   | `tensorflowlite_c` |
| ONNXRuntime | Active            | [microsoft/onnxruntime](https://github.com/microsoft/onnxruntime)                       | `onnxruntime`      |
| LibTorch    | Planned           | [pytorch/pytorch](https://github.com/pytorch/pytorch)                                    | `torch`            |

## Releases & CI

Backends are versioned independently but **released together, keyed to the anira
version**: tag `v2.0.3` builds every backend at its pinned `engines/<backend>/VERSION`
and publishes all archives to a single release `v2.0.3`.

## License

This repo is licenced under [Apache-2.0](./LICENSE).
The **published binaries** are built/repackaged from upstream and follow **their** licenses:

| Backend     | License    | Upstream license |
| ----------- | ---------- | ---------------- |
| LiteRT      | Apache-2.0 | [tensorflow/LICENSE](https://github.com/tensorflow/tensorflow/blob/master/LICENSE) |
| ONNXRuntime | MIT        | [onnxruntime/LICENSE](https://github.com/microsoft/onnxruntime/blob/main/LICENSE) |
| LibTorch    | BSD-3      | [pytorch/LICENSE](https://github.com/pytorch/pytorch/blob/main/LICENSE) |
