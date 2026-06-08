# TODO

## Verify on first CI run (current round: Windows + macOS + Linux, x64/arm64 + macOS universal)
- [ ] Static bundling produces a complete `libtensorflowlite_c.a` (no missing symbols) — `shared/bundle-static.sh`
- [ ] Windows static bundling via `lib.exe` works end-to-end

## Deferred (parked, scripts/rows kept)
- [ ] macOS Developer ID codesigning — `shared/sign-macos.sh` ready; CI cert import + secrets TODO
- [ ] wasm — Emscripten flags (`-matomics -msimd128 -mbulk-memory`) in `CMakeLists.txt`; re-add `wasm` row
- [ ] iOS — Bazel build (`litert/build-ios-bazel.sh`) + xcframework (`shared/make-xcframework.sh`) + CI job
- [ ] Android — re-add rows from `litert/ci-matrix.deferred.json`

## Later
- [ ] Backends: `onnxruntime/`, `libtorch/`
- [ ] Linux `armv7l` (Bela) — needs `-DTFLITE_ENABLE_XNNPACK=OFF`
- [ ] Contribute `SOURCE_DIR` input to `tanh-lab/ci-actions/cmake-build` (drop our workaround)

## Done
- [x] TFLite C-API target + header layout (matched to faressc/tflite-c-lib)
- [x] Static build flag (`TFLITE_C_BUILD_SHARED_LIBS=OFF`) + dep bundling
- [x] macOS universal (lipo)
- [x] Windows `lib.exe` env via `ilammy/msvc-dev-cmd`
