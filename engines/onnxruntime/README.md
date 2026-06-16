# ONNXRuntime (static + shared, full op set)

Builds `onnxruntime` (C API, **full operator set** — any model works, CPU provider only)
for [anira](https://github.com/anira-project/anira). ONNX Runtime ships only *shared*
libs upstream, so **static is built from source** (no op-reduction — every operator
ships); **shared** is built for macOS but **repackaged** from Microsoft's prebuilts
elsewhere. A **WASM** (Emscripten) static lib is built from source too — for anira
compiled to WebAssembly.

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

## Build notes (non-obvious bits)

- **Windows: Ninja + cl**, not build.py's default `Visual Studio 17 2022` generator — the
  runner images ship VS 18, which that generator can't find ("could not find any instance of
  Visual Studio"). Ninja+cl is VS-version agnostic.
- **Windows arm64: `onnxruntime_USE_KLEIDIAI=OFF` + `onnxruntime_USE_SVE=OFF`** — their `.S`
  matmul microkernels are assembled by `armasm64.exe`, which rejects `/arch:armv8.2`
  (error A2029). Other arm64 targets (clang) keep them.
- **re2 force-build.** onnxruntime include-attaches re2 (`EXCLUDE_FROM_ALL`) but never links
  it on desktop, so a normal build doesn't compile it → the static bundle misses `re2::RE2`.
  We build the `re2` target after `build.py` (with Ninja it builds by name) and force it from
  source everywhere with `CMAKE_DISABLE_FIND_PACKAGE_re2=ON`.
- **`onnxruntime_ENABLE_MEMLEAK_CHECKER=OFF`** for `Debug` — else it aborts at clean exit
  over onnxruntime's never-freed singletons.
- **`onnxruntime_ENABLE_LTO=OFF`** — pins MSVC `/GL`+`/LTCG` off (the ort-builder LTCG-patch
  effect; the literal patch no longer applies to 1.26).
- **Bundle exclude** narrowed to `/testdata/` + `libprotobuf`/`libprotoc` (build-time only;
  onnxruntime runs on protobuf-lite).
- **Smoke linking** (in `test/CMakeLists.txt`): Windows static needs the matching CRT
  (`/MD`|`/MDd`) + `advapi32` + `ucrt[d]`, and the `/MDd` run needs the non-redist debug CRT
  DLLs next to the exe; macOS needs `-framework Foundation -framework CoreFoundation`; Linux
  needs `rt`/`dl`/`m`.
- **iOS** `build.py` flag is `--apple_sysroot` (renamed from `--ios_sysroot` in 1.26).
- **WASM** (`build-ort.sh wasm`): `--build_wasm_static_lib` builds one **self-contained**
  `libonnxruntime_webassembly.a` (all deps bundled by `bundle_static_library` via `emar`) —
  so the wasm leg skips the re2 force-build *and* `bundle-static.sh`; `stage.sh` just renames
  it to `libonnxruntime.a`. Built with `--enable_wasm_simd --enable_wasm_threads --disable_rtti`
  (the ort-builder recipe). `build.py` installs+activates its own pinned **emsdk 4.0.23** from
  the `cmake/external/emsdk` submodule (init'd in `build-ort.sh`) — no external emsdk needed.
  **Threads** ⇒ the consuming wasm app must link `-pthread` and be served cross-origin-isolated
  (COOP/COEP). The CI smoke **links** the test against the `.a` with `em++` (proving the archive
  is symbol-complete — the Android arm64 compile+link gate). A forward-pass *run* belongs in a
  cross-origin-isolated browser, not headless Node (the threaded module aborts at `Env` init in
  Node's proxy worker), so it isn't part of the gate.

## Local build

```bash
# from this directory
bash build-ort.sh macos arm64 Release build           # <platform> <arch> <config> <build-dir> [kind]
bash build-ort.sh macos arm64 Release build shared    # shared variant (libonnxruntime.dylib)
bash build-ort.sh wasm wasm32 Release build           # WASM static lib (needs emsdk submodule)
bash ../../scripts/bundle-static.sh build/Release /tmp/out/lib/libonnxruntime.a   # static only (not wasm)
```
