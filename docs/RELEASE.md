# Releases & CI

## Release model — keyed to the anira version

Each backend is versioned independently — `engines/<backend>/VERSION` pins the
upstream version that gets built — but they are **released together, keyed to the
anira version**, not to the engine version.

Pushing anira's release tag — e.g. `v2.0.3` — triggers every backend workflow. Each
builds (or repackages) its backend at its pinned `VERSION` and uploads all archives
to a **single GitHub release named for that tag** (`v2.0.3`). anira `v2.0.3`'s CMake
then fetches from `releases/download/v2.0.3/…`, so its download URLs are keyed to its
own version — stable and predictable.

| You do…                                              | Runs                              | Publishes to    |
| ---------------------------------------------------- | --------------------------------- | --------------- |
| Push `engines/<backend>/**` or `shared/**` (branch/PR) | that backend **validates** only   | —               |
| Tag `v2.0.3` (the next anira version)                | **every** backend builds at its pinned `VERSION` | release `v2.0.3` |

Engine versions are internal: they pin what's built and appear in archive names
(`onnxruntime-1.26.0-macOS-arm64-static.zip`), but the **release tag is the anira
version**. Path filters mean a branch/PR push only validates the touched backend
(`shared/**` validates all); tags publish.

```bash
git tag v2.0.3 && git push origin v2.0.3    # build every backend, publish to release v2.0.3
```

## Archive layout

What anira expects inside each archive:

```
<archive>/
├── include/   # public C/C++ headers
└── lib/        # shared (.dylib/.so/.dll) and/or static (.a/.lib); Android: lib/<abi>/…
```

Naming: `<lib>-<engine-version>-<platform>-<arch>-<kind>[-debug].zip` — the platform/arch
token is the canonical `vendor.anira.name` from the preset (ARM = `aarch64` on Linux, `arm64`
elsewhere, `arm64-v8a` for Android ABIs), and `-<kind>` (`shared`/`static`) is **always**
present (e.g. `tensorflowlite_c-2.17.0-Windows-x86_64-static-debug.zip`,
`libtorch-2.12.0-macOS-arm64-shared.zip`, `onnxruntime-1.26.0-iOS-xcframework.zip`).

## Smoke gate

Every built artifact is validated before it can ship: each job compiles a smoke test
against the **packaged** archive (the link proves the `.a`/`.lib` is symbol-complete)
and runs a real **forward pass** on runnable targets. A broken artifact fails the job.

- **LiteRT** — `add.bin`, input `{1,3}` → output `{3,9}`.
- **ONNXRuntime** — `add.onnx` (`y = x + x`), input `{1,2,3}` → output `{2,4,6}`.

Runs natively on desktop; iOS on the simulator (`simctl`), Android x86_64 on a
KVM-accelerated emulator (arm64-v8a is compile+link only — software emulation hangs).

## Build & infrastructure

**Presets are the single source of truth.** Every build leg is one preset in the root
`CMakePresets.json`; the preset's `cacheVariables` drive the build and its `vendor.anira`
block carries the CI + naming metadata (runner, canonical name, kind, config, arch, canRun,
toolchain, source, prebuilt-URL bits). There is **no `ci-matrix.json`** — the `engine-meta`
action jq-generates the matrix from the presets.

**One CMake orchestrator builds every engine.** `cmake --preset <preset>` → `cmake --build`
→ `cmake --install --prefix staging/<archive>` produces a uniform tree for any engine on any
platform: litert is a native CMake build (`add_subdirectory`); onnx/libtorch run their own
build/repackage via `cmake/ExternalEngine.cmake` → `engines/<backend>/stage.sh`.

**Workflows are thin.** `litert.yml` / `onnxruntime.yml` / `libtorch.yml` only derive
meta + call the shared `_build-backend.yml` pipeline. The reusable CI "verbs" are in-repo
composite actions (`.github/actions/`): `engine-meta`, `setup-toolchain`, `stage-build`,
`publish-release`. Base compilers/Ninja come from [`tanh-lab/ci-actions`](https://github.com/tanh-lab/ci-actions)
(`setup-cpp-build-tools`), pinned to a SHA. Shared cross-backend scripts (package, sign,
static bundling) live in `shared/`; per-backend build/smoke/repackage/stage/ios scripts in
`engines/<backend>/`.

Static libs are merged from their scattered component archives into one drop-in lib
by `shared/bundle-static.sh` (macOS `libtool`, Linux `ar -M`, Windows `lib.exe`).

## Codesigning

Currently **off**. `shared/sign-macos.sh` is ready (Developer ID for Hardened-Runtime
DAW hosts) but unused; Windows Authenticode optional. iOS frameworks and Android/Linux
need no signing.
