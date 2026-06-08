# TODO

## Verify on first CI run (current round: Windows + macOS + Linux, x64/arm64 + macOS universal)
- [x] macOS x64/arm64 build (NEON_2_SSE fix) + static bundling — validated locally
- [ ] Windows static bundling via `lib.exe` works end-to-end (Ninja+MSVC)
- [ ] Windows arm64 cross-compile (CMAKE_SYSTEM_NAME=Windows) configures/builds
- [ ] Linux x64/aarch64 build + bundle
- [ ] macos-universal job works with upload-artifact@v7 / download-artifact@v8 (multi-major bump)

## Deferred (parked, scripts/rows kept)
- [ ] macOS Developer ID codesigning — `shared/sign-macos.sh` ready; CI cert import + secrets TODO
- [ ] wasm — Emscripten flags (`-matomics -msimd128 -mbulk-memory`) in `CMakeLists.txt`; re-add `wasm` row
- [ ] iOS — Bazel build (`engines/litert/build-ios-bazel.sh`) + xcframework (`shared/make-xcframework.sh`) + CI job
- [ ] Android — re-add rows from `engines/litert/ci-matrix.deferred.json`

## Later
- [ ] Backends: `onnxruntime/`, `libtorch/`
- [ ] Linux `armv7l` (Bela) — needs `-DTFLITE_ENABLE_XNNPACK=OFF`
- [ ] Contribute `SOURCE_DIR` input to `tanh-lab/ci-actions/cmake-build` (drop our workaround)

## Done
- [x] TFLite C-API target + header layout (matched to faressc/tflite-c-lib)
- [x] Static build flag (`TFLITE_C_BUILD_SHARED_LIBS=OFF`) + dep bundling
- [x] macOS universal (lipo)
- [x] Windows `lib.exe` env via `ilammy/msvc-dev-cmd`
