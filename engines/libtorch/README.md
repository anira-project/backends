# LibTorch (PyTorch C++)

CPU-only **shared** libtorch at the version in [`VERSION`](./VERSION), packaged for
[anira](https://github.com/anira-project/anira). Unlike LiteRT/ONNXRuntime (flat
`include/`+`lib/`), libtorch ships a full CMake package tree and is consumed via
`find_package(Torch)` — so archives preserve `include/`, `lib/`, **`share/cmake/Torch/`**
(and `bin/` where present).

## Target matrix (shared, 2.12.0)

| Platform   | Arch    | Source        | Upstream archive / how                                   |
| ---------- | ------- | ------------- | -------------------------------------------------------- |
| 🍎 macOS   | arm64   | **build**     | from source — matches x86_64 so the universal lipo has matched slices |
| 🍎 macOS   | x86_64  | **build**     | no prebuilt since 2.2.2 (Intel-mac dropped) → from source |
| 🐧 Linux   | x86_64  | **prebuilt**  | `libtorch-shared-with-deps-<v>+cpu.zip`                  |
| 🐧 Linux   | aarch64 | **build**     | no aarch64 in the `cpu/` index → from source             |
| 🪟 Windows | x86_64  | **prebuilt**  | `libtorch-win-shared-with-deps-<v>+cpu.zip`              |
| 🪟 Windows | arm64   | **build**     | no 2.12.0 release prebuilt → from source with **native ARM64 MSVC `cl`** |

> **Windows arm64** builds from source with the **native ARM64 MSVC `cl`** toolchain
> (`vcvarsall.bat arm64`), mirroring PyTorch's own win-arm64 CI
> (`.ci/pytorch/windows/arm64/build_libtorch.bat`) — **not** clang-cl. An earlier clang-cl
> attempt hit an x64-target mismatch, an OOM under emulation, and the `uint` NEON-vec error;
> native `cl` is PyTorch's actual toolchain and sidesteps all three.
| 🍎 macOS   | universal | **build (lipo)** | lipo of the two per-arch from-source archives          |

The macOS **universal** archive is `lipo`'d from the two per-arch *from-source* macOS
archives (identical build config → matched dylib sets — the prerequisite for a clean
lipo). Both macOS arches build from source for this reason, mirroring LiteRT/ONNXRuntime;
the official prebuilt arm64 isn't used (lipo'ing it against our from-source x86_64 would
risk mismatched dylib sets).

> The from-source targets are first-pass recipes (see `build-libtorch.sh`);
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
