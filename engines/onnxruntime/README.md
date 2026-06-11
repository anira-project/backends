# ONNXRuntime (static + shared, full op set)

Builds `onnxruntime` (C API, **full operator set** — any model works, CPU provider only)
for [anira](https://github.com/anira-project/anira). ONNX Runtime ships only *shared*
libs upstream, so **static is built from source** (no op-reduction — every operator
ships); **shared** is built for macOS but **repackaged** from Microsoft's prebuilts
elsewhere.

## Target matrix

| Platform    | Arch                     | `static`                       | `shared`                |
| ----------- | ------------------------ | ------------------------------ | ----------------------- |
| 🍎 macOS    | x86_64, arm64, universal | ✅ built                       | 🚧 built (+ `lipo`)     |
| 🪟 Windows  | x64, arm64               | ✅ built `Release` + `Debug`   | 🚧 upstream prebuilt    |
| 🐧 Linux    | x86_64, aarch64          | ✅ built                       | 🚧 upstream prebuilt    |
| 🤖 Android  | arm64-v8a, x86_64        | ✅ built (multi-ABI bundle)    | 🚧 from Maven AAR       |
| 📱 iOS      | device + simulator       | ✅ built xcframework           | —                       |

`static` = built from source everywhere (one merged lib via `bundle-static.sh`).
`shared` = built for 🍎 macOS (so the universal slices match), **repackaged** from
upstream prebuilts for 🪟🐧🤖 (no build — `onnxruntime-osx-x86_64` is the only CPU
shared lib Microsoft doesn't ship, hence we build all of macOS ourselves).

## Files

| File                  | Purpose                                                      |
| --------------------- | ------------------------------------------------------------ |
| `VERSION`             | Pinned upstream version (single source of truth)             |
| `build-ort.sh`        | Per-target build via onnxruntime's `tools/ci_build/build.py` |
| `repackage-shared.sh` | Restage upstream prebuilt `shared` libs (Linux/Win/Android)  |
| `stage.sh`            | Build/repackage + bundle, staged into the install prefix (orchestrator + CI) |
| `ios.sh`              | Build device+sim → `.xcframework` (+ simulator smoke)        |
| `include/`            | Vendored ONNX Runtime C/C++ API headers                      |
| `test/CMakeLists.txt` | CMake smoke consumer (imported target; run via the smoke action / ctest) |
| `test/smoke.cpp`      | Forward-pass smoke (`add.onnx`, `y = x + x` → `{2,4,6}`)     |
| `test/add.onnx`       | Tiny model the smoke runs                                     |

## Static-build notes (non-obvious bits)

- **re2 force-build.** onnxruntime include-attaches re2 (`EXCLUDE_FROM_ALL`) but never
  links it on desktop, so a normal build doesn't compile it → the static bundle misses
  `re2::RE2`. We build the `re2` target after `build.py` (on Windows VS, by the project's
  real path), with `CMAKE_DISABLE_FIND_PACKAGE_re2=ON` to force it from source everywhere.
- **`onnxruntime_ENABLE_MEMLEAK_CHECKER=OFF`** for `Debug` — else it aborts at clean exit
  over onnxruntime's never-freed singletons.
- **`onnxruntime_ENABLE_LTO=OFF`** — pins MSVC `/GL`+`/LTCG` off (the ort-builder LTCG-patch
  effect; the literal patch no longer applies to 1.26).
- **Bundle exclude** narrowed to `/testdata/` (not `-src/`) — some deps build in-source.

## Local build

```bash
# from this directory
bash build-ort.sh macos arm64 Release build           # <platform> <arch> <config> <build-dir> [kind]
bash build-ort.sh macos arm64 Release build shared    # shared variant (libonnxruntime.dylib)
bash ../../scripts/bundle-static.sh build/Release /tmp/out/lib/libonnxruntime.a   # static only
```
