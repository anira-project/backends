# ExecuTorch (PyTorch on-device runtime)

CPU-first **static** ExecuTorch runtime at the version in [`VERSION`](./VERSION), packaged
for [anira](https://github.com/anira-project/anira). Like libtorch (and unlike the flat
`include/`+`lib/` of TFLite/ONNXRuntime) ExecuTorch ships a CMake package tree and is
consumed via **`find_package(executorch CONFIG)`** — so archives preserve `include/`, `lib/`
and **`lib/cmake/ExecuTorch/`** (`executorch-config.cmake` + `ExecuTorchTargets.cmake`).

## Generic runtime, not a per-model selective build

ExecuTorch's headline feature is shrinking the runtime to one model's ops. We deliberately
do the **opposite**: link the whole optimized CPU kernel library
(`optimized_native_cpu_ops_lib`) + the portable kernels + XNNPACK, so a **single package
loads any `.pte`**. The model graph is still pared down ahead-of-time on the export side
(the `.pte`), but the shipped runtime is general. The config bakes `-force_load` into the
imported targets' link interface, so op/backend static initializers register despite static
linking (the failure mode that makes static libtorch fragile is handled upstream here).

## CPU by default; GPU delegates ship as separate -gpu variants

Every platform builds the optimized CPU kernels + **XNNPACK** (the CPU path anira uses now);
the default packages contain nothing else. GPU delegates live in the separate `-gpu` variant
archives ([`docs/gpu-support.md`](../../docs/gpu-support.md)): on Apple the **CoreML**
delegate (ANE/GPU) and, on arm64, the **MLX** delegate (which floors that one package at
macOS 14+; the CPU default stays at 12.0); on Linux x64 the cross-vendor **Vulkan** delegate
(experimental — shaders compile with `glslc` at build time; the loader is dlopen'd via volk,
so there's no hard runtime dependency). Windows Vulkan is a follow-up (needs the Vulkan SDK
toolchain on the runner).

> Streaming caveat (from the neural_tilde external, worth knowing before enabling GPU):
> XNNPACK and CoreML persist `cached_conv` streaming state across `execute()`; **MLX does
> not** (streaming models click). Keep streaming models on XNNPACK/CoreML.

## Source: always from source

PyTorch ships ExecuTorch only as Python wheels (the AOT exporter) and mobile prebuilts
(iOS `.xcframework` / Android `.aar`) — there is **no upstream prebuilt desktop C++ runtime**
to repackage. So every desktop leg builds from source; there is no `prebuilt` mode.

## Files

| File                  | Purpose                                                                 |
| --------------------- | ----------------------------------------------------------------------- |
| `VERSION`             | Pinned ExecuTorch version (single source of truth)                      |
| `build-executorch.sh` | Build the static CPU+XNNPACK runtime from source (`accel=` adds CoreML/MLX/Vulkan for -gpu variants)|
| `stage.sh`            | Dispatch to the from-source build, staged into the install prefix       |
| `test/CMakeLists.txt` | `find_package(executorch CONFIG)` smoke (run via the smoke action/ctest)|
| `test/smoke.cpp`      | Loads `add.pte` and runs `a+b -> {3,5,7}`; link-only fallback otherwise  |
| `test/export_add.py`  | Exports the trivial `add.pte` via the pinned wheel (for the smoke)      |

## Archive naming

`executorch-<version>-<os>-<arch>-static.zip`, e.g. `executorch-1.3.1-macOS-arm64-static.zip`,
`executorch-1.3.1-Linux-aarch64-static.zip`, `executorch-1.3.1-Windows-x86_64-static.zip`
(`os` ∈ macOS/Linux/Windows, `arch` ∈ arm64/x86_64/aarch64). Each extracts to
`include/ lib/` (with `lib/cmake/ExecuTorch/`) — point `CMAKE_PREFIX_PATH` at it and
`find_package(executorch CONFIG)`.

## Local build

```bash
bash engines/executorch/build-executorch.sh macos arm64 /tmp/out   # native arm64 host
cmake -S engines/executorch/test -B /tmp/smoke -DCMAKE_PREFIX_PATH=/tmp/out \
  && cmake --build /tmp/smoke && ctest --test-dir /tmp/smoke --output-on-failure
```

Needs Python 3.12 + a C++17 toolchain. The smoke's real model-load leg additionally needs
`pip install torch executorch==<VERSION>` so `export_add.py` can produce `add.pte`; without
them the smoke degrades to a link + `runtime_init()` check.

## Build notes

- **Static, CPU-first.** Flags follow ExecuTorch's own platform presets
  (`tools/cmake/preset/{apple_common,linux,windows}.cmake` at the pinned tag), stated
  explicitly so an upstream preset rename can't silently drop one.
- **Codegen needs Python.** ExecuTorch's CMake kernel-binding codegen imports the
  `executorch` python package + `pyyaml` at configure time; the build puts the source tree on
  `PYTHONPATH` (codegen is pure-python, no compiled extension needed just to generate op libs).
- **Apple delegates.** CoreML embeds its model in the `.pte` (no sidecar) and needs macOS 15+
  at runtime; MLX (arm64 only) ships an `mlx.metallib` bundled next to the libs.
- **Windows.** MSVC `cl` via the workflow's MSVC env + Ninja; the LLM/custom kernels are
  disabled (upstream warns they need `-T ClangCL` on MSVC — not needed for the CPU runtime).
  `git core.longpaths` for ExecuTorch's deep submodule paths.
- **These recipes are first-pass** — like the other from-source engines they may need a CI
  round per platform when the pinned version changes.
