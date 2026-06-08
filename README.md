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

`libtensorflowlite_c`, CPU only (XNNPACK; no GPU/NPU). Most targets are **built from
source** (CMake, with our `bundle-static.sh` merging deps for static); **iOS is the
exception** — Google ships an official prebuilt xcframework, so we download + repackage it.
Every artifact is validated by a **smoke-test gate** (compile + link + a forward pass on
native targets — see [Smoke test](#smoke-test-gate)).

| Target           | OS      | Arch              | How              | Shared/Static | Status |
| ---------------- | ------- | ----------------- | ---------------- | ------------- | ------ |
| `macosx64`       | macOS   | x86_64            | CMake            | both          | active |
| `macosarm64`     | macOS   | arm64             | CMake            | both          | active |
| `macosuniversal` | macOS   | x86_64 + arm64    | CMake + `lipo`   | both          | active |
| `windowsx64`     | Windows | x64               | CMake (Ninja+MSVC) | both        | active |
| `windowsarm64`   | Windows | arm64             | CMake (Ninja+MSVC, native `windows-11-arm`) | both | active (no XNNPACK) |
| `linuxx64`       | Linux   | x86_64            | CMake            | both          | active |
| `linuxaarch64`   | Linux   | aarch64           | CMake            | both          | active |
| `android`        | Android | arm64-v8a, x86_64 | CMake / NDK      | static        | active (one multi-ABI archive) |
| `ios`            | iOS     | device + simulator| **download** Google's prebuilt `.xcframework` | static | active |
| `wasm`           | Web     | wasm32            | CMake / Emscripten | static      | deferred |

### Notes

- **macOS universal** = `lipo` of `macosx64` + `macosarm64`.
- **Android** ships as **one multi-ABI archive** (`lib/<abi>/…`, the AAR/NDK convention),
  not per-ABI artifacts. Each ABI is built separately then combined.
- **iOS** = Google's official `TensorFlowLiteC.xcframework` (device + simulator, static,
  privacy manifest). We don't build it (no static C-API prebuilt exists for Android, but
  iOS has one). Headers are framework-style (`<TensorFlowLiteC/c_api.h>`).
- **Windows-arm64** disables XNNPACK — MSVC can't build XNNPACK's NEON microkernels.
- **Windows static**: consumers must compile with `-DTFL_STATIC_LIBRARY_BUILD`, else the
  C-API header uses `__declspec(dllimport)` and the link fails.
- **Codesigning** is currently **off** — `shared/sign-macos.sh` is ready (Developer ID for
  Hardened-Runtime/DAW hosts) but unused; Windows Authenticode optional/not done. iOS static
  framework and Android/Linux need no signing.
- **wasm** (deferred) is static-only and ABI-tied to anira-web's Emscripten build
  (`-matomics -msimd128 -mbulk-memory`, emsdk **4.0.23**), so archives are keyed by emsdk
  version. Mirrors anira's web branch ([`Andonvr/anira`](https://github.com/Andonvr/anira)).

### Archive naming

```
desktop:  tensorflowlite_c-<version>-<OS>-<arch>[-<accel>][-static].zip   # OS ∈ {macOS, Windows, Linux}
android:  tensorflowlite_c-<version>-Android-static.zip                   # lib/<abi>/…
ios:      tensorflowlite_c-<version>-iOS-xcframework.zip                  # TensorFlowLiteC.xcframework
wasm:     tensorflowlite_c-<version>-wasm-emsdk-<emsdk-version>.zip
```

`<accel>` omitted = CPU/XNNPACK (the only variant built — see below). The mobile/web targets
are new and need companion changes in anira's `cmake/SetupTensorflowLite.cmake` to be consumed
(it currently fetches shared desktop variants only).

### Smoke test gate

After packaging, every job compiles `engines/litert/test/smoke.cpp` against the **packaged**
artifact (the static link proves the bundled `.a`/`.lib` is symbol-complete) and runs a real
forward pass on native targets — TFLite's `add.bin` model: input `{1,3}` → output `{3,9}`. A
broken artifact fails the job before it can be published. Cross-only / non-native targets
(iOS, Windows-arm64 build host, Android) compile+link without the run.

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
backends/                          # repo root
├── VERSION                        # this repo's own semver (e.g. 0.0.1)
├── engines/
│   └── litert/                    # one dir per backend (onnxruntime/, libtorch/ later)
│       ├── VERSION                # pinned upstream version (single source of truth)
│       ├── CMakeLists.txt         # fetch tensorflow + build/install
│       ├── CMakePresets.json      # one preset per target
│       └── ci-matrix*.json        # active / deferred build matrices
├── shared/                        # package / sign / bundle-static / xcframework scripts
└── .github/workflows/
    ├── litert.yml                 # triggers + matrix → reusable workflow
    └── _build-backend.yml         # reusable: build → bundle → package → upload
```

### Versions & tags

Two version lines, each with a `VERSION` file as its source of truth; **tags only trigger,
they don't carry the version** (keeps anira's URLs stable at `releases/download/litert-v<ver>/`):

- **per-backend** — `engines/<backend>/VERSION` (the upstream version, e.g. LiteRT `2.17.0`)
- **repo** — root `./VERSION` (this repo's own semver, e.g. `0.0.1`)

| Tag              | Effect                                                  | Must match     |
| ---------------- | ------------------------------------------------------- | -------------- |
| `litert-v2.17.0` | release LiteRT only                                     | `engines/litert/VERSION` |
| `v0.0.1`         | repo release — rebuild every backend at its own VERSION | `./VERSION`    |

```bash
git tag litert-v2.17.0 && git push origin litert-v2.17.0   # one backend
git tag v0.0.1         && git push origin v0.0.1           # repo release (everything)
```

### Triggers

Path filters mean only the touched backend builds (`shared/**` rebuilds all). Plain
push/PR = **validate only**; tags **publish** (assets refreshed in place per release).

| You do…                         | Runs                     | Publishes               |
| ------------------------------- | ------------------------ | ----------------------- |
| Push `engines/litert/**` (branch/PR)    | LiteRT validate          | —                       |
| Edit `shared/**` (branch/PR)    | every backend validate   | —                       |
| Tag `litert-v2.17.0`            | LiteRT release           | `litert-v2.17.0`        |
| Tag `v0.0.1` (repo release)     | all backends release     | each `<backend>-v<ver>` |

## License

Repo scripts under the repo `LICENSE`; produced binaries follow their upstream licenses
(LiteRT/TensorFlow: Apache-2.0).
