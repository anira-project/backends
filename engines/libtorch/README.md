# LibTorch (PyTorch C++)

CPU-only **shared** libtorch at the version in [`VERSION`](./VERSION), packaged for
[anira](https://github.com/anira-project/anira). Unlike LiteRT/ONNXRuntime (flat
`include/`+`lib/`), libtorch ships a full CMake package tree and is consumed via
`find_package(Torch)` — so archives preserve `include/`, `lib/`, **`share/cmake/Torch/`**
(and `bin/` where present).

## Static builds — not supported

Unlike LiteRT and ONNXRuntime, LibTorch ships **shared only**. Static is intentionally
out of scope:

- **No static prebuilts exist for 2.12.0.** Upstream static archives
  (`libtorch-*-static-with-deps-*`) stopped at **2.1.2** and were Linux-x86_64 only —
  Windows/macOS static were never published. Static at 2.12.0 would mean building from
  source on every platform.
- **Static libtorch is fragile.** PyTorch's operator/dispatcher registration depends on
  global static initializers the linker strips from an archive unless the consumer
  force-loads (`-Wl,--whole-archive` / `-force_load`). It's poorly maintained upstream,
  breaks far more often than the shared build, and the archives are very large.

If a static requirement ever comes up, it's a from-source-only effort to revisit
deliberately — not a quick `BUILD_SHARED_LIBS=0` flip.

## Files

| File                  | Purpose                                                        |
| --------------------- | ------------------------------------------------------------- |
| `VERSION`             | Pinned PyTorch version (single source of truth)               |
| `repackage.sh`        | Download an upstream prebuilt, restage the full package tree  |
| `build-libtorch.sh`   | Build CPU shared libtorch from source (the three gaps)        |
| `stage.sh`            | Repackage or build, staged into the install prefix (orchestrator + CI) |
| `test/CMakeLists.txt` | `find_package(Torch)` smoke (run via the smoke action / ctest) |
| `test/smoke.cpp`      | Forward pass: `a+b -> {3,5,7}`, `dot(a,b) -> 20`              |

## Archive naming

`libtorch-<version>-<os>-<arch>-shared.zip`, e.g. `libtorch-2.12.0-macOS-arm64-shared.zip`,
`libtorch-2.12.0-Linux-aarch64-shared.zip`, `libtorch-2.12.0-Windows-x86_64-shared.zip`
(`os` ∈ macOS/Linux/Windows, `arch` ∈ arm64/x86_64/aarch64; `-shared` kind suffix is always
present). Each extracts to `include/ lib/ share/ [bin/]` — point `CMAKE_PREFIX_PATH` at it and
`find_package(Torch)`.

## Local repackage (prebuilt targets)

```bash
bash engines/libtorch/repackage.sh \
  https://download.pytorch.org/libtorch/cpu/libtorch-macos-arm64-2.12.0.zip \
  /tmp/out                                   # -> /tmp/out/{include,lib,share}
cmake -S engines/libtorch/test -B /tmp/smoke -DCMAKE_PREFIX_PATH=/tmp/out && cmake --build /tmp/smoke && ctest --test-dir /tmp/smoke --output-on-failure
```

## Local build (from-source targets)

```bash
bash engines/libtorch/build-libtorch.sh linux aarch64 /tmp/out   # native arm64 host
cmake -S engines/libtorch/test -B /tmp/smoke -DCMAKE_PREFIX_PATH=/tmp/out && cmake --build /tmp/smoke && ctest --test-dir /tmp/smoke --output-on-failure
```

Needs Python 3.12 + PyTorch's build deps; Linux aarch64 needs `libopenblas-dev`.

## Build notes

**Source per target**: Linux-x86_64 and Windows-x86_64 repackage upstream
`download.pytorch.org` prebuilts; macOS (both arches), Linux-aarch64 and Windows-arm64 build
from source (no matching CPU prebuilt at 2.12.0). The macOS **universal** archive is `lipo`'d
from the two from-source per-arch builds — both build from source so their dylib sets match
(a clean lipo needs matched slices; the official prebuilt arm64 isn't used).

- **CPU-only config**: `USE_CUDA/ROCM/CUDNN/NCCL/DISTRIBUTED/MPI=0`. `USE_MKLDNN`+`FBGEMM`
  on for x86_64 (off for arm64 — FBGEMM is x86-only). BLAS: Accelerate on macOS, OpenBLAS on
  Linux aarch64, Eigen on Windows arm64 (self-contained).
- **Windows arm64**: native ARM64 MSVC `cl`, **not** clang-cl (`vcvarsall.bat arm64`,
  mirroring PyTorch's own win-arm64 CI). VS ships only x64 clang-cl → an earlier clang-cl
  attempt hit an x64-target mismatch, OOM under emulation, and a `uint` NEON-vec error;
  native `cl` sidesteps all three. `MAX_JOBS=2` on the 16 GB runner; `git core.longpaths`
  (PyTorch `test/` paths exceed `MAX_PATH`); install only `requirements-build.txt` (the full
  reqs drag in `lintrunner`, which has no win-arm64 wheel).
- **macOS x86_64**: builds on `macos-15-intel` (the last Intel image; PyTorch dropped Intel-mac
  libtorch after 2.2.2). It's a heavy oneDNN+FBGEMM compile that runs close to GitHub's 6-hour
  hosted-runner cap — if it ever caps, trim the build (`USE_MKLDNN=0`) or add compile caching.
  `USE_NATIVE_ARCH=0`/`USE_MPS=0` dodge the Apple-Clang `-mavx512fp16` failure.
- **These recipes are first-pass** — like LiteRT/ONNXRuntime they may need a CI round per
  platform when the pinned version changes.
