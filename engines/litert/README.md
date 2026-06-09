# LiteRT (TensorFlow Lite C API)

Builds `libtensorflowlite_c` from upstream `tensorflow/lite/c` at the version in
[`VERSION`](./VERSION), packaged for [anira](https://github.com/anira-project/anira).
CPU only (XNNPACK; no GPU/NPU). Release model & CI: [docs/RELEASE.md](../../docs/RELEASE.md).

## Target matrix

| Platform    | Arch                  | `shared`        | `static`                  | How                         |
| ----------- | --------------------- | --------------- | ------------------------- | --------------------------- |
| 🍎 macOS    | x86_64, arm64, universal | ✅           | ✅                        | CMake (+ `lipo` universal)  |
| 🪟 Windows  | x64                   | ✅              | ✅ `Release` + `Debug`    | CMake (Ninja + MSVC)        |
| 🪟 Windows  | arm64                 | ✅              | ✅ `Release` + `Debug`    | CMake — no XNNPACK¹         |
| 🐧 Linux    | x86_64, aarch64       | ✅              | ✅                        | CMake                       |
| 🤖 Android  | arm64-v8a, x86_64     | 🚧 deferred     | ✅ multi-ABI bundle       | CMake / NDK                 |
| 📱 iOS      | device + simulator    | —               | ✅ xcframework            | **download** Google prebuilt |
| 🌐 Web      | wasm32                | —               | 🚧 deferred               | CMake / Emscripten          |

¹ Windows-arm64 disables XNNPACK (MSVC can't build its NEON microkernels).

### Consuming the Windows `static` lib

- `-DTFL_STATIC_LIBRARY_BUILD` — else the C-API header uses `__declspec(dllimport)` (link fails).
- match the CRT — `/MD` for `-static`, `/MDd` for `-static-debug` (cl defaults to `/MT` → `LNK2038`).
- link `advapi32.lib` (cpuinfo's registry calls) + the matching `ucrt[d].lib`.

## Files

| File                      | Purpose                                          |
| ------------------------- | ------------------------------------------------ |
| `VERSION`                 | Pinned upstream version (single source of truth) |
| `CMakeLists.txt`          | Fetch tensorflow, build + install the C API      |
| `CMakePresets.json`       | One preset per target (platform × shared/static) |
| `ci-matrix.json`          | Active CI build matrix                           |
| `ci-matrix.deferred.json` | Parked rows (Android `shared`, wasm)             |
| `test/smoke.cpp`          | Forward-pass smoke (`add.bin` → `{3,9}`)         |

> iOS isn't built here — it repackages Google's prebuilt `TensorFlowLiteC.xcframework`
> (the `ios-xcframework` job in `_build-backend.yml`).

## Local build

```bash
cmake --preset macos-arm64-shared      # or *-static, linux-x64-shared, … (cmake --list-presets)
cmake --build --preset macos-arm64-shared -j
cmake --install build/macos-arm64-shared --prefix /tmp/out   # -> /tmp/out/{include,lib}
```

Android needs `ANDROID_NDK_HOME`; wasm needs `EMSDK` (4.0.23, to match anira-web's ABI).
