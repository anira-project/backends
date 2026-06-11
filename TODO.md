# TODO

- Cut a release tag (`v<x.y.z>`) and verify the published archives load (the publish path ran for the first time on the green branch run).
- macOS Developer ID codesigning — wire cert import + secrets into the dormant `.github/actions/sign-macos` (signing is currently off).
- Android `arm64-v8a` smoke is compile+link only (software emulation hangs; `x86_64` runs the real forward pass).
- Android shared run-on-emulator smoke (currently compile+link only — the `.so` may need `libc++_shared.so` on-device).
- wasm — Emscripten target/preset (re-add the deferred `wasm` row; `-matomics -msimd128 -mbulk-memory`).
- ExecuTorch backend — researching (static + AOT `.pte` model).
- Linux `armv7l` (Bela) — needs `-DTFLITE_ENABLE_XNNPACK=OFF`.
