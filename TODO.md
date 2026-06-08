# TODO

## Status (current round: Windows + macOS + Linux, x64/arm64 + macOS universal)
- [x] macOS x64/arm64 + Linux x64/aarch64, shared + static (green in CI)
- [x] Windows x64 shared/static + Windows arm64 static (green in CI; Ninja+MSVC, native windows-11-arm)
- [x] Windows arm64: XNNPACK disabled (MSVC can't build NEON microkernels) — fixes arm64-shared DLL link
- [x] C++ smoke test (compile+link+forward-pass gate) — validated locally
- [ ] macos-universal green (was skipped while a build job failed) + smoke gate green in CI

## Deferred (parked, scripts/rows kept)
- [ ] macOS Developer ID codesigning — `shared/sign-macos.sh` ready; CI cert import + secrets TODO
- [ ] wasm — Emscripten flags (`-matomics -msimd128 -mbulk-memory`) in `CMakeLists.txt`; re-add `wasm` row
- [x] iOS — repackage Google's prebuilt `TensorFlowLiteC.xcframework` (download, not build) + compile/link smoke
- [ ] iOS — run smoke as a forward pass on the booted simulator (needs a test .app bundle)
- [x] Android (static, multi-ABI bundle) — added; Android shared still parked

## Consumer notes (document in README)
- Windows **static**: consumers must compile with `-DTFL_STATIC_LIBRARY_BUILD` or the
  C API header uses `__declspec(dllimport)` and the link fails (`__imp_TfLite*`).

## Later
- [ ] Backends: `onnxruntime/`, `libtorch/`
- [ ] Linux `armv7l` (Bela) — needs `-DTFLITE_ENABLE_XNNPACK=OFF`
- [ ] Contribute `SOURCE_DIR` input to `tanh-lab/ci-actions/cmake-build` (drop our workaround)

## Done
- [x] TFLite C-API target + header layout (matched to faressc/tflite-c-lib)
- [x] Static build flag (`TFLITE_C_BUILD_SHARED_LIBS=OFF`) + dep bundling
- [x] macOS universal (lipo)
- [x] Windows `lib.exe` env via `ilammy/msvc-dev-cmd`
