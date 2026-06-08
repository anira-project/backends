# LiteRT (TensorFlow Lite C API)

Builds `libtensorflowlite_c` from upstream `tensorflow/lite/c` at the version in
[`VERSION`](./VERSION), packaged for [anira](https://github.com/anira-project/anira).
See the [repo README](../../README.md) for the target matrix and release model, and
[`TODO.md`](../../TODO.md) for open work.

## Files

| File                  | Purpose                                          |
| --------------------- | ------------------------------------------------ |
| `VERSION`             | Pinned upstream version (single source of truth) |
| `CMakeLists.txt`      | Fetch tensorflow, build + install the C API      |
| `CMakePresets.json`   | One preset per target (platform × shared/static) |
| `ci-matrix.json`      | Active CI build matrix                           |
| `ci-matrix.deferred.json` | Parked rows (Android shared, wasm)           |
| `test/smoke.cpp`      | Forward-pass smoke test (add.bin → `{3,9}`)      |

> iOS isn't built here — it repackages Google's prebuilt `TensorFlowLiteC.xcframework`
> (see the `ios-xcframework` job in `_build-backend.yml`).

## Local build

```bash
cmake --preset macos-arm64-shared      # or *-static, linux-x64-shared, … (cmake --list-presets)
cmake --build --preset macos-arm64-shared -j
cmake --install build/macos-arm64-shared --prefix /tmp/out   # -> /tmp/out/{include,lib}
```

Android needs `ANDROID_NDK_HOME`; wasm needs `EMSDK` (4.0.23, to match anira-web's ABI).
