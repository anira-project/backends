# ONNXRuntime (static, full op set)

Builds **static** `onnxruntime` from source for [anira](https://github.com/anira-project/anira),
with the **full operator set** (any model works) and CPU provider only.

ONNX Runtime ships only *shared* libraries in its releases, so static is built from source —
following the spirit of [olilarkin/ort-builder](https://github.com/olilarkin/ort-builder)
**minus the op-reduction** (we keep every operator). The build emits many component `.a`/`.lib`;
these are merged into one drop-in lib by [`shared/bundle-static.sh`](../../shared/bundle-static.sh).

## Files

| File             | Purpose                                                       |
| ---------------- | ------------------------------------------------------------- |
| `VERSION`        | Pinned upstream version (single source of truth)              |
| `build-ort.sh`   | Per-target build via onnxruntime's `tools/ci_build/build.py`  |
| `smoke-onnx.sh`  | Compile+link+run the smoke against the packaged static lib    |
| `ci-matrix.json` | Active CI build matrix                                        |
| `include/`       | Vendored ONNX Runtime C/C++ API headers                       |
| `test/smoke.cpp` | Smoke test (links the lib, creates an `OrtEnv`)               |

## Targets (static)

macOS x64 / arm64 / universal · Windows x64 / arm64 (Release **and** Debug) · Linux x64 / aarch64 ·
Android arm64-v8a / x86_64 (multi-ABI bundle) · iOS xcframework (device + simulator).

Windows ships a Debug **and** a Release lib so consumers can CRT-match (`/MDd` vs `/MD`). The iOS
xcframework is **built** here (device + simulator slices), not downloaded — ONNX has no prebuilt
static framework. Releases are published under the `onnxruntime-v<version>` tag.

## Local build

```bash
# from this directory
bash build-ort.sh macos arm64 Release build      # <platform> <arch> <config> <build-dir>
# platform ∈ {macos, linux, windows, android, ios, ios-sim}
bash ../../shared/bundle-static.sh build/Release /tmp/out/lib/libonnxruntime.a
```

## Static-build notes (non-obvious bits)

These took some digging and are encoded in `build-ort.sh` / the workflow:

- **re2 must be force-built.** onnxruntime declares re2 `EXCLUDE_FROM_ALL` and only
  *include*-attaches it (`onnxruntime_add_include_to_target`, not `target_link_libraries`) on
  every non-WinML target, so a normal build never compiles it — the shared lib just tolerates the
  undefined `re2::RE2` symbols. The static bundle needs the objects, so we build the `re2` target
  explicitly after `build.py` (and on the Windows VS generator, by the project's real path).
- **`CMAKE_DISABLE_FIND_PACKAGE_re2=ON`** forces re2 from source everywhere; otherwise the Windows
  runners' prebuilt re2 is picked up and no re2 target is generated to build/bundle.
- **`onnxruntime_ENABLE_MEMLEAK_CHECKER=OFF`** for Debug — build.py turns it on, which aborts the
  process at exit over onnxruntime's never-freed global singletons (a Debug lib that crashes on
  clean teardown).
- **Bundle exclude** is narrowed to `/testdata/` (not the default `-src/`), since some deps build
  in-source.
