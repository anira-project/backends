# LiteRT (native C API)

Builds LiteRT's **native C API** — `libLiteRt` (`LiteRt*` symbols) — from
[google-ai-edge/LiteRT](https://github.com/google-ai-edge/LiteRT) at the version in
[`VERSION`](./VERSION), packaged for [anira](https://github.com/anira-project/anira). CPU-only.

> **Distinct from the `tflite` engine.** `tflite` builds the legacy TensorFlow Lite C API
> (`tensorflowlite_c`, `TfLite*` symbols) from `tensorflow/lite/c`. This engine builds LiteRT's
> newer native C API (`litert/c/*.h`, `LiteRtEnvironment`/`LiteRtCompiledModel`/…). They are
> different API surfaces — a consumer targets one or the other.

## What ships

- **shared** (`libLiteRt.{so,dylib,dll}`): macOS (x86_64/arm64/universal), Linux (x86_64/aarch64),
  Windows (x86_64 **and arm64**), Android (arm64-v8a/x86_64), iOS (xcframework). macOS dylibs are
  Developer ID code-signed.
- **static** (one merged `libLiteRt.a` / `LiteRt.lib`): macOS (x86_64/arm64/universal), Linux
  (x86_64/aarch64), Windows (x86_64 **and arm64**), Android (arm64-v8a/x86_64, multi-ABI bundle).
- Only iOS `static` isn't provided (iOS ships the prebuilt xcframework).

## Build

Driven by the root orchestrator (CPU-only: GPU + NPU off):

```bash
cmake --preset litert-linux-x86_64-shared      # cmake --list-presets for the rest
cmake --build  build/litert-linux-x86_64-shared
cmake --install build/litert-linux-x86_64-shared --prefix /tmp/out   # -> /tmp/out/{include,lib}
```

Headers (all legs) come from the `litert_cc_sdk.zip` release asset + a synthesized CPU-only
`build_config.h`. The library is produced two ways:

- **`source=prebuilt`** — fetch the official `libLiteRt` from `litert/prebuilt/<platform>/` (Git-LFS,
  via the `media.githubusercontent.com` endpoint), pinned to a `main` SHA. Used for `shared` where a
  prebuilt exists (everything but macOS x86_64), and for the iOS xcframework (device + simulator).
- **`source=build`** — Bazel build (`bazelisk` + Python, set up by `setup-toolchain`). Used for
  macOS x86_64 `shared` and for **all `static`** (upstream ships no static lib).

### Static build

There is no static prebuilt, so `stage.sh` builds the C API impl cc_library
(`//litert/c:litert_runtime_c_api_so_shim`, the closure the shared lib links from), materialises
every transitive `cc_library` archive (`bazel build` of the cquery'd labels — the top build only
emits `.o`), then merges the full `CcInfo` static-archive closure into one library: `libtool` on
macOS, GNU `ar` on Linux, `lib.exe`/`llvm-lib` on Windows. Per-leg specifics:

- **Linux** — `--force_pic` so the archive links into PIE consumers; on x86_64 also
  `USE_HERMETIC_CC_TOOLCHAIN=0 --noincompatible_enable_cc_toolchain_resolution` so the archive's
  `std::filesystem` ABI matches the system libstdc++ consumers link.
- **macOS x86_64** — the Apple platform transition (`--config=macos --platforms=…:macos_x86_64`) the
  shared dylib rule applies internally, else tflite's x86 `NEON_2_SSE.h` is unwired.
- **Windows arm64** — no prebuilt, so both `shared` (`libLiteRt.dll` + synthesized import lib) and
  `static` are built from source. Built **natively** on a `windows-11-arm` runner with **clang-cl**
  (MSVC `cl` can't compile deps' GCC/clang constructs like `__builtin_expect`), pinned **LLVM 20**
  (Bazel 7.x mis-detects newer LLVM's clang resource dir — bazelbuild/bazel#17863), a current
  **cpuinfo** override (the pinned one's arm64-Windows source has a since-fixed bug), and **XNNPACK
  disabled** (its pinned Bazel build has no arm64-Windows microkernels) — CPU kernels via
  ruy/builtin. Static archives merged with `llvm-lib`.
- **Android `static`** — built from source inside LiteRT's public `ml-build` container (which
  provisions the `cuda_redist`/`rules_ml_toolchain` externals a bare runner lacks); the container
  install adds clang + NDK r25b + SDK, then builds the closure and merges per ABI (`engines/litert/
  android-build.sh`). `shared` Android stays the official prebuilt `.so`.

## Files

| File                  | Purpose                                                              |
| --------------------- | -------------------------------------------------------------------- |
| `VERSION`             | Pinned LiteRT **release** tag (not `main`)                           |
| `stage.sh`            | Prebuilt repackage or Bazel build of `libLiteRt`; shared + static    |
| `ios.sh`              | Repackage the prebuilt device + simulator dylibs into an xcframework |
| `test/CMakeLists.txt` | CMake smoke (link `libLiteRt`; run via the smoke action/ctest)       |
| `test/smoke.cpp`      | Link + load: `LiteRtCreateEnvironment` / `…Destroy…`                 |
