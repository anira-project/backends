# LibTorch (PyTorch C++)

CPU-only **shared** libtorch at the version in [`VERSION`](./VERSION), packaged for
[anira](https://github.com/anira-project/anira). Unlike LiteRT/ONNXRuntime (flat
`include/`+`lib/`), libtorch ships a full CMake package tree and is consumed via
`find_package(Torch)` — so archives preserve `include/`, `lib/`, **`share/cmake/Torch/`**
(and `bin/` where present). Release model & CI: [docs/RELEASE.md](../../docs/RELEASE.md).

## Target matrix (shared, 2.12.0)

| Platform   | Arch    | Source        | Upstream archive / how                                   |
| ---------- | ------- | ------------- | -------------------------------------------------------- |
| 🍎 macOS   | arm64   | **prebuilt**  | `libtorch-macos-arm64-<v>.zip`                           |
| 🍎 macOS   | x86_64  | **build**     | no prebuilt since 2.2.2 (Intel-mac dropped) → from source |
| 🐧 Linux   | x86_64  | **prebuilt**  | `libtorch-shared-with-deps-<v>+cpu.zip`                  |
| 🐧 Linux   | aarch64 | **build**     | no aarch64 in the `cpu/` index → from source             |
| 🪟 Windows | x86_64  | **prebuilt**  | `libtorch-win-shared-with-deps-<v>+cpu.zip`              |
| 🪟 Windows | arm64   | **build**     | 2.12.0 release not published (debug-only) → from source  |
| 🍎 macOS   | universal | **build (lipo)** | from-source x86_64 + a from-source arm64 "universal slice", lipo'd |

The macOS **universal** archive is `lipo`'d from two *from-source* slices (identical
build config → matched dylib sets — the prerequisite for a clean lipo). The per-arch
arm64 archive stays the official prebuilt; the universal consumes a separate
from-source arm64 slice (`…-macOS-arm64-universal-slice`, an intermediate, not published).

> The three from-source targets are first-pass recipes (see `build-libtorch.sh`);
> like the ONNXRuntime/LiteRT builders they are expected to need a few CI rounds to
> converge per platform. Key fixes get recorded in [`../../TODO.md`](../../TODO.md).

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
| `ci-matrix.json`      | CI matrix; `source` = `prebuilt` (download) or `build`        |
| `repackage.sh`        | Download an upstream prebuilt, restage the full package tree  |
| `build-libtorch.sh`   | Build CPU shared libtorch from source (the three gaps)        |
| `smoke-torch.sh`      | Build + run the smoke via `find_package(Torch)`               |
| `test/smoke.cpp`      | Forward pass: `a+b -> {3,5,7}`, `dot(a,b) -> 20`              |
| `test/CMakeLists.txt` | `find_package(Torch)` consumer (mirrors anira's path)         |

## Archive naming

`libtorch-<version>-<os>-<arch>.zip`, e.g. `libtorch-2.12.0-macOS-arm64.zip`,
`libtorch-2.12.0-Linux-aarch64.zip`, `libtorch-2.12.0-Windows-x86_64.zip`
(`os` ∈ macOS/Linux/Windows, `arch` ∈ arm64/x86_64/aarch64). Each extracts to
`include/ lib/ share/ [bin/]` — point `CMAKE_PREFIX_PATH` at it and `find_package(Torch)`.

## Local repackage (prebuilt targets)

```bash
bash engines/libtorch/repackage.sh \
  https://download.pytorch.org/libtorch/cpu/libtorch-macos-arm64-2.12.0.zip \
  /tmp/out                                   # -> /tmp/out/{include,lib,share}
bash engines/libtorch/smoke-torch.sh /tmp/out engines/libtorch/test 1
```

## Local build (from-source targets)

```bash
bash engines/libtorch/build-libtorch.sh linux aarch64 /tmp/out   # native arm64 host
bash engines/libtorch/smoke-torch.sh /tmp/out engines/libtorch/test 1
```

Needs Python 3.12 + PyTorch's build deps; Linux aarch64 needs `libopenblas-dev`.
