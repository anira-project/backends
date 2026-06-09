# anira-backends

Prebuilt inference-engine binaries for [anira](https://github.com/anira-project/anira).
Each backend is built from source (or repackaged from an upstream prebuilt) and
published as GitHub release archives that anira's CMake (`cmake/Setup*.cmake`)
downloads at configure time.

## Backends

| Backend     | Status            | Upstream                                                                                | lib name           |
| ----------- | ----------------- | --------------------------------------------------------------------------------------- | ------------------ |
| LiteRT      | Active            | [google-ai-edge/LiteRT](https://github.com/google-ai-edge/LiteRT) (ex-TensorFlow Lite)  | `tensorflowlite_c` |
| ONNXRuntime | Active            | [microsoft/onnxruntime](https://github.com/microsoft/onnxruntime)                       | `onnxruntime`      |
| LibTorch    | Planned           | [pytorch/pytorch](https://github.com/pytorch/pytorch)                                    | `torch`            |

Per-backend target matrices live in each engine's README
([LiteRT](./engines/litert/README.md) · [ONNXRuntime](./engines/onnxruntime/README.md)).

## Releases & CI

Backends are versioned independently but **released together, keyed to the anira
version**: tag `v2.0.3` builds every backend at its pinned `engines/<backend>/VERSION`
and publishes all archives to a single release `v2.0.3`. Branch/PR pushes validate
only. Full details — release model, archive layout, the smoke gate —
in [**docs/RELEASE.md**](./docs/RELEASE.md). Open work: [`TODO.md`](./TODO.md).

## License

This repo's scripts/CI are **Apache-2.0** ([`LICENSE`](./LICENSE)). The **published
binaries** are built/repackaged from upstream and follow **their** licenses:

| Backend     | License    | Upstream license |
| ----------- | ---------- | ---------------- |
| LiteRT      | Apache-2.0 | [tensorflow/LICENSE](https://github.com/tensorflow/tensorflow/blob/master/LICENSE) |
| ONNXRuntime | MIT        | [onnxruntime/LICENSE](https://github.com/microsoft/onnxruntime/blob/main/LICENSE) |
| LibTorch    | BSD-3      | [pytorch/LICENSE](https://github.com/pytorch/pytorch/blob/main/LICENSE) |

A built backend statically bundles further third-party deps (each under its own
license — see the upstream repos' `third_party/`/`LICENSE`).
