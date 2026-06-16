# TODO

- Android `arm64-v8a` smoke is compile+link only (software emulation hangs; `x86_64` runs the real forward pass).
- Android shared run-on-emulator smoke (currently compile+link only — the `.so` may need `libc++_shared.so` on-device).
- wasm — ONNXRuntime done (`onnx-wasm-static`, `--build_wasm_static_lib` + simd/threads). TFLite next
  (Emscripten CMake build, `-matomics -msimd128 -mbulk-memory`); LiteRT deferred (Bazel+emscripten — use the TFLite C API on WASM).
- ExecuTorch backend — researching (static + AOT `.pte` model).
- Linux `armv7l` (Bela) — needs `-DTFLITE_ENABLE_XNNPACK=OFF`.
