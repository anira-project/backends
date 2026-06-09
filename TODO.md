# TODO

## Done — LiteRT, all platforms green + smoke-gated
- macOS x64 / arm64 / universal — shared + static
- Linux x64 / aarch64 — shared + static
- Windows x64 / arm64 — shared + static + **static-debug** (Ninja+MSVC; arm64 native on `windows-11-arm`)
- Android — static multi-ABI bundle (`arm64-v8a` + `x86_64`)
- iOS — repackaged from Google's prebuilt `TensorFlowLiteC.xcframework`
- Smoke gate runs a real forward pass (`add.bin` → `{3,9}`) on every runnable target:
  desktop natively, iOS on the simulator, Android x86_64 on the emulator

### Key fixes / facts (so we don't relearn them)
- Windows static: force dynamic CRT `/MD` (`CMAKE_MSVC_RUNTIME_LIBRARY`); smoke must compile
  `/MD` (cl CLI defaults to `/MT` → `LNK2038`); link `advapi32.lib`; `-DTFL_STATIC_LIBRARY_BUILD`.
- Windows debug static: `/Z7` (no PDB → no `C1041`); **no sccache** for Debug.
- Windows arm64: XNNPACK off (MSVC can't build NEON microkernels).
- macOS x64 / iOS-sim-x86_64: force `CMAKE_SYSTEM_PROCESSOR` so TFLite fetches the NEON_2_SSE shim.
- CMake 4 + old TFLite deps: `CMAKE_POLICY_VERSION_MINIMUM=3.5` (preset env).
- Android smoke: `-static-libstdc++` (no `libc++_shared.so` on device).
- Static bundling: macOS `libtool`, Linux `ar -M addlib`, Windows `lib.exe` (all wholesale-merge).

## Done — ONNXRuntime (static, full ops), all platforms green + smoke-gated
- macOS x64 / arm64 / universal — static
- Linux x64 / aarch64 — static
- Windows x64 / arm64 — static, **Release and Debug** (VS/MSVC; arm64 native on `windows-11-arm`)
- Android — static multi-ABI bundle (`arm64-v8a` + `x86_64`)
- iOS — **built** here (device + simulator → `onnxruntime.xcframework`); no prebuilt static exists
- Smoke: compile + link + `OrtEnv` init against the packaged static lib (run on native targets)

### Key fixes / facts (so we don't relearn them)
- Built from source (no static prebuilt ships); `bundle-static.sh` merges component `.a`/`.lib`.
- **re2 force-build**: onnxruntime include-attaches re2 (`EXCLUDE_FROM_ALL`) but never links it on
  desktop, so a normal build doesn't compile it → static bundle misses `re2::RE2`. Build the `re2`
  target after `build.py` (on Windows VS, by the project's real path — `cmake --build --target re2`
  hits MSB1009). `CMAKE_DISABLE_FIND_PACKAGE_re2=ON` forces it from source everywhere (else the
  Windows runner's prebuilt re2 is used, no source target to build/bundle).
- **Debug**: `onnxruntime_ENABLE_MEMLEAK_CHECKER=OFF` — build.py enables it for Debug and it aborts
  at clean exit over never-freed singletons (smoke prints PASS, then exits 127).
- **Windows LTCG**: `onnxruntime_ENABLE_LTO=OFF` already drops MSVC `/GL`+`/LTCG`, so ort-builder's
  `ltcg_patch_for_windows.patch` is unnecessary. Libs are still large (full-op static).
- **Windows smoke**: don't name the staging dir `LIB` (clobbers MSVC's `LIB` env → `advapi32.lib`
  not found, LNK1181) — use `LIBDIR`; link `advapi32.lib` + matching `ucrt[d].lib`; copy the debug
  CRT DLLs next to the exe for the `/MDd` run.
- **macOS smoke**: link `-framework Foundation -framework CoreFoundation`.
- **Bundle exclude** narrowed to `/testdata/` (not `-src/`) — some deps build in-source.
- iOS `build.py` flag is `--apple_sysroot` (renamed from `--ios_sysroot` in 1.26).

### Still open (ONNXRuntime)
- **Publish**: cut `onnxruntime-v1.26.0` to run the release path (combine + iOS jobs ran for the
  first time on the green branch run — verify the published archives are correct/loadable).
- **anira-side**: `cmake/SetupOnnxRuntime.cmake` to consume the new archives (static `.a`/`.lib`,
  xcframework on iOS, multi-ABI on Android).

## Deferred
- macOS Developer ID codesigning — `shared/sign-macos.sh` ready; CI cert import + secrets TODO (both backends)
- wasm — Emscripten flags (`-matomics -msimd128 -mbulk-memory`); re-add `wasm` row (matches anira-web)
- Android arm64-v8a smoke = compile+link only (software-emulation on x64 hangs; official NDK has no
  linux-aarch64 host for a native arm runner). x86_64 runs the real forward pass.
- Android shared `.so` (parked in `ci-matrix.deferred.json`)

## Later
- Backends: `libtorch/` (and researching `executorch/` — static + AOT `.pte` model question)
- Linux `armv7l` (Bela) — needs `-DTFLITE_ENABLE_XNNPACK=OFF`
- anira-side: `cmake/SetupTensorflowLite.cmake` to consume the new mobile/static archives
- Contribute a `SOURCE_DIR` input to `tanh-lab/ci-actions/cmake-build` (drop our workaround)
