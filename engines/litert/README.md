# LiteRT (native C API)

Builds LiteRT's **native C API** — `libLiteRt` (`LiteRt*` symbols) — from
[google-ai-edge/LiteRT](https://github.com/google-ai-edge/LiteRT) at the version in
[`VERSION`](./VERSION), packaged for [anira](https://github.com/anira-project/anira). CPU-only,
**shared**.

> **Distinct from the `tflite` engine.** `tflite` builds the legacy TensorFlow Lite C API
> (`tensorflowlite_c`, `TfLite*` symbols) from `tensorflow/lite/c`. This engine builds LiteRT's
> newer native C API (`litert/c/*.h`, `LiteRtEnvironment`/`LiteRtCompiledModel`/…). They are
> different API surfaces — a consumer targets one or the other.

> **Status: in progress (first-pass).** LiteRT's only all-platform build is **Bazel** (CMake
> presets exist only for macOS/Linux/Android upstream), so the engine builds `libLiteRt` via
> Bazel from a `stage.sh` — the same way onnx/libtorch shell out to their build systems. Like
> those, the per-platform recipe is expected to need CI iteration; Windows + iOS (Bazel-only
> upstream) are the hardest legs. iOS is deferred until a `litert/ios.sh`.

## Build

Driven by the root orchestrator (CPU-only: GPU + NPU off):

```bash
cmake --preset litert-linux-x86_64-shared      # cmake --list-presets for the rest
cmake --build  build/litert-linux-x86_64-shared
cmake --install build/litert-linux-x86_64-shared --prefix /tmp/out   # -> /tmp/out/{include,lib}
```

`stage.sh` clones LiteRT at the pinned release tag, runs `bazel build
//litert/c:litert_runtime_c_api_shared_lib`, and stages `include/litert/c/*.h` + `lib/libLiteRt.*`.
Needs `bazelisk` + Python (handled by `setup-toolchain` for `engine == litert`).

## Files

| File                  | Purpose                                                       |
| --------------------- | ------------------------------------------------------------- |
| `VERSION`             | Pinned LiteRT **release** tag (not `main`)                    |
| `stage.sh`            | Bazel build of `libLiteRt`, staged into the install prefix    |
| `test/CMakeLists.txt` | CMake smoke (link `libLiteRt`; run via the smoke action/ctest) |
| `test/smoke.cpp`      | Link + load: `LiteRtCreateEnvironment` / `…Destroy…`          |

## Build notes (first-pass)

- **Bazel is the build.** `bazelisk` picks the repo-pinned Bazel (`.bazelversion`). Per-platform
  `--config` from LiteRT's CI (`bulk_test_cpu`, `macos_<arch>`, `android_<arch>`, `windows`, `ios_arm64`).
- **CPU-only**: `--define=litert_disable_gpu=true --define=litert_disable_npu=true` (mirrors the
  repo's `-DLITERT_ENABLE_GPU=OFF -DLITERT_ENABLE_NPU=OFF`). Residual OpenGL/XNNPACK link deps may
  remain — refine per leg.
- **Static is deferred** — the clean Bazel target is the shared `libLiteRt`; static needs a
  different target/whole-archive handling.
