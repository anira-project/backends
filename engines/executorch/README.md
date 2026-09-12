# ExecuTorch (PyTorch on-device runtime)

CPU-only **static** ExecuTorch runtime at the version in [`VERSION`](./VERSION), packaged
for [anira](https://github.com/anira-project/anira) as **one merged archive** — a flat
`include/` + `lib/libexecutorch.a` tree like the onnxruntime/litert/tflite static packages
(`executorch.lib` + `executorch_registrations.lib` on Windows, an `executorch.xcframework` on
iOS, `lib/<abi>/libexecutorch.a` on Android). No CMake package, no `find_package`, and no
force-load on the consumer side.

## Generic runtime, not a per-model selective build

ExecuTorch's headline feature is shrinking the runtime to one model's ops. We deliberately
do the **opposite**: link the whole optimized CPU kernel library
(`optimized_native_cpu_ops_lib`) + the quantized kernels + XNNPACK, so a **single package
loads any `.pte`**. The model graph is still pared down ahead-of-time on the export side
(the `.pte`), but the shipped runtime is general.

## How the registrations survive a plain archive link

ExecuTorch registers operator kernels and delegate backends from **static initializers**.
Nothing references those TUs, so an on-demand archive link drops them and every model fails
at execute — which is why upstream bakes `-force_load` into its exported CMake targets.
`merge-static.sh` instead partial-links (`ld -r`) the registering archives together with the
runtime core (`executorch_core`, `executorch`, `optimized_native_cpu_ops_lib`,
`quantized_ops_lib`, `xnnpack_backend`, plus `xnnpack-microkernels-prod`, whose dispatch
tables ld64 cannot resolve on demand) into **one archive member**: any use of the runtime
pulls that member, initializers included. The remaining libs join as ordinary on-demand
members. Windows has no partial link, so the same set ships as a second small
`executorch_registrations.lib` that the consumer links with `/WHOLEARCHIVE`.

The script cross-checks the exported `ExecuTorchTargets.cmake`: every library upstream
force-loads must be classified (registered once, or excluded — `portable_ops_lib` &
co. re-register the same aten ops and would abort at startup), so a version bump that adds
a registering library fails the build instead of silently shipping unregistered kernels.

## CPU by default; GPU delegates ship as separate -gpu variants

Every platform builds the optimized/portable/quantized CPU kernels + **XNNPACK** (the CPU path
anira uses now); the default packages contain nothing else, and their smoke asserts that no
GPU delegate is registered. With the registrations pre-linked, a delegate is either registered
for every consumer or absent — there is no "present but inert, switch on later" state — which
is exactly why GPU delegates live in the separate `-gpu` variant archives:

- macOS `-gpu` (`accel=coreml`): the **CoreML** delegate (ANE/GPU) + the **MPS** delegate,
  and on arm64 the **MLX** delegate (which floors that one package at macOS 14+; the CPU
  default stays at 12.0). `libmlx.a` joins the merged archive and `mlx.metallib` ships next
  to it. Consumers link CoreML, Accelerate, Foundation, sqlite3, Metal,
  MetalPerformanceShaders, MetalPerformanceShadersGraph.
- iOS `-gpu` xcframework: CoreML + MPS delegates (same frameworks).
- Linux x64 `-gpu` (`accel=vulkan`, experimental): the cross-vendor **Vulkan** delegate —
  shaders compile with `glslc` at build time; the loader is dlopen'd via volk, so there is no
  hard runtime dependency. Windows Vulkan is a follow-up (needs the Vulkan SDK toolchain on
  the runner); Android Vulkan is the next mobile wave.

`merge-static.sh` takes the delegate set through `MERGE_DELEGATES` (`coremldelegate
mpsdelegate mlxdelegate vulkan_backend`): each delegate's `register_backend()` TU joins the
pre-linked blob and its dependency libs leave the exclusion list. The variant smoke asks the
runtime's backend registry (`get_backend_class`) for exactly those names.

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
| `build-executorch.sh` | Build the static CPU+XNNPACK runtime from source (`accel=` adds the CoreML/MPS/MLX or Vulkan delegates for -gpu variants), stage include/ + merged lib |
| `merge-static.sh`     | Merge the built libs into one archive with the registrations pre-linked (`MERGE_DELEGATES` adds a -gpu variant's delegates) |
| `stage.sh`            | Dispatch to the from-source build, staged into the install prefix       |
| `ios.sh`              | Build both iOS slices via ExecuTorch's presets, merge, `.xcframework`   |
| `test/CMakeLists.txt` | Links the merged archive like anira does (run via the smoke action/ctest)|
| `test/smoke.cpp`      | Loads `add.pte` and runs `a+b -> {3,5,7}`; link-only fallback otherwise  |
| `test/export_add.py`  | Exports the trivial `add.pte` via the pinned wheel (for the smoke)      |

## Archive naming

`executorch-<version>-<os>-<arch>-static.zip`, e.g. `executorch-1.3.1-macOS-arm64-static.zip`,
`executorch-1.3.1-Linux-aarch64-static.zip`, `executorch-1.3.1-Windows-x86_64-static.zip`
(`os` ∈ macOS/Linux/Windows, `arch` ∈ arm64/x86_64/aarch64). Each extracts to
`include/ lib/libexecutorch.a` — add the include dir (plus
`include/executorch/runtime/core/portable_type/c10` for the vendored c10, and
`-DC10_USING_CUSTOM_GENERATED_MACROS -DET_LOG_ENABLED=0 -DET_USE_THREADPOOL`) and link the
archive. Windows: `lib/executorch.lib` + `/WHOLEARCHIVE:lib/executorch_registrations.lib`.

## Local build

```bash
bash engines/executorch/build-executorch.sh macos arm64 /tmp/out   # native arm64 host
cmake -S engines/executorch/test -B /tmp/smoke -DCMAKE_PREFIX_PATH=/tmp/out \
  && cmake --build /tmp/smoke && ctest --test-dir /tmp/smoke --output-on-failure
```

Needs a Python with a `torch==2.12.0` wheel (3.12–3.14) + a C++17 toolchain. The smoke runs
the committed `add.pte` through the merged archive (a dropped registration fails there at
execute, never at link); without it the smoke degrades to a link + `runtime_init()` check.

## Build notes

- **Static, CPU-first.** Flags follow ExecuTorch's own platform presets
  (`tools/cmake/preset/{apple_common,linux,windows}.cmake` at the pinned tag), stated
  explicitly so an upstream preset rename can't silently drop one.
- **Codegen needs Python.** ExecuTorch's CMake kernel-binding codegen imports the
  `executorch` python package + `pyyaml` at configure time; the build puts the source tree on
  `PYTHONPATH` (codegen is pure-python, no compiled extension needed just to generate op libs).
- **Deployment target** 12.0 on both macOS arches (MLX was what forced 14.0 on arm64).
- **Windows.** MSVC `cl` via the workflow's MSVC env + Ninja; the LLM/custom kernels are
  disabled (upstream warns they need `-T ClangCL` on MSVC — not needed for the CPU runtime).
  `git core.longpaths` for ExecuTorch's deep submodule paths.
- **These recipes are first-pass** — like the other from-source engines they may need a CI
  round per platform when the pinned version changes.
