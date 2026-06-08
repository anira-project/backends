# anira-backends

Prebuilt inference-engine binaries for [anira](https://github.com/anira-project/anira).
Each backend is built from source and published as GitHub release archives that anira's
CMake (`cmake/Setup*.cmake`) downloads at configure time. Open work: [`TODO.md`](./TODO.md).

Archive layout (what anira expects):

```
<archive>/
├── include/   # public C/C++ headers
└── lib/        # shared (.dylib/.so/.dll) and/or static (.a/.lib)
```

## Backends

| Backend     | Status      | Upstream                                                          | lib name           |
| ----------- | ----------- | ---------------------------------------------------------------- | ------------------ |
| LiteRT      | In progress | [google-ai-edge/LiteRT](https://github.com/google-ai-edge/LiteRT) (ex-TensorFlow Lite) | `tensorflowlite_c` |
| ONNXRuntime | Planned     | [microsoft/onnxruntime](https://github.com/microsoft/onnxruntime) | `onnxruntime`      |
| LibTorch    | Planned     | [pytorch/pytorch](https://github.com/pytorch/pytorch)            | `torch`            |

---

## LiteRT — target matrix

`libtensorflowlite_c`, CPU only (XNNPACK; no GPU/NPU). Shared + static for every target.
**Current round builds Windows + macOS + Linux** (see [`TODO.md`](./TODO.md)); iOS/Android/wasm
are parked in `litert/ci-matrix.deferred.json`.

| Target           | OS      | Arch              | Build tool         | Round   | Notes |
| ---------------- | ------- | ----------------- | ------------------ | ------- | ----- |
| `macosx64`       | macOS   | x86_64            | CMake              | active  | min macOS 11.0 |
| `macosarm64`     | macOS   | arm64             | CMake              | active  | min macOS 11.0 |
| `macosuniversal` | macOS   | x86_64 + arm64    | CMake + `lipo`     | active  | fat of the two above |
| `windowsx64`     | Windows | x64               | CMake / MSVC       | active  | |
| `windowsarm64`   | Windows | arm64             | CMake / MSVC       | active  | cross-compiled |
| `linuxx64`       | Linux   | x86_64            | CMake              | active  | |
| `linuxaarch64`   | Linux   | aarch64           | CMake              | active  | |
| `wasm`           | Web     | wasm32            | CMake / Emscripten | deferred| threads+SIMD, emsdk-keyed |
| `ios`            | iOS     | arm64 + sim       | Bazel              | deferred| `.xcframework` |
| `android`        | Android | arm64-v8a, x86_64 | CMake / NDK        | deferred| |

### Notes

- **macOS universal** = `lipo` of `macosx64` + `macosarm64`.
- **Codesigning** — macOS needs Developer ID so the lib loads into Hardened-Runtime /
  Library-Validation hosts (DAWs, notarized apps); `shared/sign-macos.sh` is ready but
  **off this round**. Windows Authenticode is optional (not done). Linux/Android/wasm: none.
- **wasm** is static-only and must be ABI-compatible with anira-web's Emscripten build
  (`-matomics -msimd128 -mbulk-memory`, emsdk **4.0.23**), so archives are keyed by emsdk
  version. Mirrors anira's web branch ([`Andonvr/anira`](https://github.com/Andonvr/anira)).
- **iOS** requires Bazel (`//tensorflow/lite/ios:TensorFlowLiteC_framework`); CMake has no iOS path.

### Archive naming

```
tensorflowlite_c-<version>-<OS>-<arch>[-<accel>][-static].zip
wasm:  tensorflowlite_c-<version>-wasm-emsdk-<emsdk-version>.zip
```

`OS ∈ {macOS, Windows, Linux, iOS, Android}`. `<accel>` omitted = CPU/XNNPACK (the only
variant built — see below). New mobile/web/static targets need companion changes in anira's
`cmake/SetupTensorflowLite.cmake` (it currently fetches shared desktop only).

### Hardware acceleration (roadmap)

CPU-only today (XNNPACK = SIMD CPU, not an accelerator). GPU/NPU would ship as *additional*
artifacts (`-coreml`, `-gpu`) without restructuring, and need anira to call
`TfLiteInterpreterOptionsAddDelegate`. Only realistic on:

| Platform    | Possible accel                      | Extra libs                            |
| ----------- | ----------------------------------- | ------------------------------------- |
| iOS         | Core ML (ANE), Metal GPU            | `CoreML.framework`, `Metal.framework` |
| macOS arm64 | Core ML (ANE), Metal GPU            | + `Accelerate`                        |
| Android     | GPU (OpenCL/OpenGL), Qualcomm NPU   | GPU delegate lib, vendor SDKs         |

Windows / Linux / wasm stay CPU-only (no usable delegate via the C API).

---

## Releases & CI

Each backend builds and releases **independently** (one workflow each, since their builds
differ). Build steps reuse [`tanh-lab/ci-actions`](https://github.com/tanh-lab/ci-actions)
(`setup-cpp-build-tools`), **pinned to a SHA**. Packaging, signing, `lipo`, static bundling,
and release upload live in `shared/` + `_build-backend.yml`.

### Layout

```
backends/
├── litert/
│   ├── VERSION                # pinned upstream version (single source of truth)
│   ├── CMakeLists.txt         # fetch tensorflow + build/install
│   ├── CMakePresets.json      # one preset per target
│   └── ci-matrix*.json        # active / deferred build matrices
├── onnxruntime/ libtorch/     # (later)
├── shared/                    # package / sign / bundle-static / xcframework scripts
└── .github/workflows/
    ├── litert.yml             # triggers + matrix → reusable workflow
    └── _build-backend.yml     # reusable: build → bundle → package → upload
```

### Version & tags

`VERSION` is the only source of the version; **tags are triggers/labels, not the version**.
This keeps anira's URLs stable (`releases/download/litert-v<VERSION>/...`).

| Tag                | Effect                                        |
| ------------------ | --------------------------------------------- |
| `litert-v2.17.0`   | release LiteRT (CI checks tag == `VERSION`)   |
| `all-v3`           | release every backend at its own `VERSION`    |

```bash
git tag litert-v2.17.0 && git push origin litert-v2.17.0   # one backend
git tag all-v3          && git push origin all-v3           # everything
```

### Triggers

Path filters mean only the touched backend builds (`shared/**` rebuilds all). Plain
push/PR = **validate only**; tags **publish** (assets refreshed in place per release).

| You do…                         | Runs                     | Publishes               |
| ------------------------------- | ------------------------ | ----------------------- |
| Push `litert/**` (branch/PR)    | LiteRT validate          | —                       |
| Edit `shared/**` (branch/PR)    | every backend validate   | —                       |
| Tag `litert-v2.17.0`            | LiteRT release           | `litert-v2.17.0`        |
| Tag `all-v3`                    | all backends release     | each `<backend>-v<ver>` |

## License

Repo scripts under the repo `LICENSE`; produced binaries follow their upstream licenses
(LiteRT/TensorFlow: Apache-2.0).
