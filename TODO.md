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

## Deferred
- macOS Developer ID codesigning — `shared/sign-macos.sh` ready; CI cert import + secrets TODO
- wasm — Emscripten flags (`-matomics -msimd128 -mbulk-memory`); re-add `wasm` row (matches anira-web)
- Android arm64-v8a smoke = compile+link only (software-emulation on x64 hangs; official NDK has no
  linux-aarch64 host for a native arm runner). x86_64 runs the real forward pass.
- Android shared `.so` (parked in `ci-matrix.deferred.json`)

## Later
- Backends: `onnxruntime/`, `libtorch/`
- Linux `armv7l` (Bela) — needs `-DTFLITE_ENABLE_XNNPACK=OFF`
- anira-side: `cmake/SetupTensorflowLite.cmake` to consume the new mobile/static archives
- Contribute a `SOURCE_DIR` input to `tanh-lab/ci-actions/cmake-build` (drop our workaround)
