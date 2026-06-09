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
- Android shared run-on-emulator smoke (currently compile+link only — the `.so` may
  need `libc++_shared.so` on-device; static x86_64 runs the full forward pass)

## In progress — LibTorch (CPU, shared), 2.12.0
Engine scaffolded at `engines/libtorch/` (VERSION, ci-matrix.json, repackage.sh,
build-libtorch.sh, smoke-torch.sh + test/, README) and `.github/workflows/libtorch.yml`.
Consumed via `find_package(Torch)`, so archives preserve `include/ lib/ share/ [bin/]`
(`shared/package.sh` gained a backward-compatible `PACKAGE_DIRS` env for this).

### Source per target (what's missing at 2.12.0)
- **Prebuilt (download + restage)**: Linux x86_64, Windows x86_64.
- **Build from source**:
  - macOS x86_64 — PyTorch dropped Intel-mac libtorch after 2.2.2 (build on `macos-15-intel`).
  - macOS arm64 — a prebuilt exists, but we build it from source anyway so the universal lipo
    has matched slices (mirrors LiteRT/ONNXRuntime; official prebuilt arm64 not used).
  - Linux aarch64 — none in the `download.pytorch.org/cpu/` index (build on `ubuntu-24.04-arm`, OpenBLAS).
  - Windows arm64 — 2.12.0 release not published (only a `-debug` build; release tops at 2.11.0).
- **Universal (macOS)**: `macos-universal` job lipos the two per-arch from-source archives.

### CI status (run 4, commit 4f985e5)
Green (incl. find_package(Torch) smoke): macOS arm64 (1h3m cold), macOS x86_64 (8m35s cached),
Linux aarch64 (2m11s cached), Linux x86_64 + Windows x86_64 (prebuilt). Failing: Windows arm64.
`macOS-universal-shared` was SKIPPED — it `needs: build`, and a win-arm64 failure marks the whole
build matrix failed. Fixed: `if: !cancelled()` so universal runs off the macOS slices regardless
of unrelated legs (still unvalidated until next run).

### Still open (LibTorch)
- **From-source recipes need CI iteration** (first-pass `build-libtorch.sh`):
  - Windows arm64 builds with **clang-cl** (`CC/CXX=clang-cl`, MSVC env for headers/libs/
    linker) — matching PyTorch's official win-arm64; MSVC `cl` trips on ARM64 NEON intrinsics.
    Gotcha (run 4): the clang-cl on PATH is VS's **x64-host** build, which defaults to an
    **x64 target** → links arm64 `msvcrtd.lib` and dies "machine type arm64 conflicts with
    x64". Fix: force `--target=arm64-pc-windows-msvc` via `CFLAGS`/`CXXFLAGS` (clang-cl is a
    cross-compiler; arm64 SDK/runtime from the MSVC env). Still untested past the compiler
    check — next failure is likely the actual ATen/sleef arm64 compile. Output stays MSVC-ABI.
  - macOS x86_64: x86_64-mac is PyTorch-deprecated but buildable from source (forum-confirmed at
    2.6; conda-forge still ships it). Runs on `macos-15-intel` — the LAST Intel image, retiring
    ~Fall 2027; after that, cross-compile on Apple-silicon `macos-15` (must solve the codegen
    host-tool problem) or self-host. `USE_NATIVE_ARCH=0`/`USE_MPS=0` set to dodge the Apple-Clang
    `-mavx512fp16` failure; if 2.12 still trips it, point CC/CXX at a brew LLVM clang.
  - Linux aarch64: `USE_MKLDNN=0`/OpenBLAS for a self-contained first pass; revisit for perf.
- **Verify repackaged tree loads**: smoke builds via `find_package(Torch)` and runs a forward pass —
  confirm against the real (huge) upstream zips, not just the synthetic test.
- **anira-side**: update `cmake/SetupLibTorch.cmake` to consume these archives from anira-backends
  releases (currently pulls `faressc/libtorch-cpp-lib` + raw pytorch.org; align the Windows
  `-release` token and the `CMAKE_SYSTEM_PROCESSOR` arch tokens to `os-arch` naming).
- **Static: not supported (decided).** No 2.12.0 static prebuilts (upstream stopped at 2.1.2,
  Linux-x86_64 only) → would be from-source on every platform, and static libtorch needs
  whole-archive/-force_load for op registration and is poorly maintained upstream. Shared only.
  See `engines/libtorch/README.md` "Static builds — not supported".
- macOS universal: wired — lipo of the two per-arch from-source archives (both macOS arches
  build from source so the dylib sets match; mirrors LiteRT/ONNXRuntime "universal needs
  matched slices"). anira keys libtorch per-arch today, so universal is for shipping
  universal plugin binaries.
- Later: iOS/Android; static (decided out — see above).

## Later
- Backends: researching `executorch/` — static + AOT `.pte` model question
- Linux `armv7l` (Bela) — needs `-DTFLITE_ENABLE_XNNPACK=OFF`
- anira-side: `cmake/SetupTensorflowLite.cmake` to consume the new mobile/static archives
- Contribute a `SOURCE_DIR` input to `tanh-lab/ci-actions/cmake-build` (drop our workaround)
