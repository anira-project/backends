// ExecuTorch smoke test: validates a packaged ExecuTorch runtime (headers + static libs +
// the ExecuTorch CMake package). Builds via find_package(executorch CONFIG) — the same path
// anira uses — which proves executorch-config.cmake resolves, every static archive links,
// and the op/backend static initializers register (the config bakes -force_load into the
// imported targets' link interface).
//
// Two modes, picked at configure time by the test CMakeLists:
//   * SMOKE_PTE defined — a real model-load+run: load an add.pte (a + b) exported by
//     export_add.py via the pinned ExecuTorch wheel, run it on the CPU portable/optimized
//     kernels, and check the exact result. This is the strong proof the runtime executes.
//         a = {1,2,3}, b = {2,3,4}  ->  a + b = {3,5,7}
//   * SMOKE_PTE undefined — link + runtime-init only (no wheel available on this runner,
//     e.g. a platform with no ExecuTorch pip wheel): initialize the runtime and confirm the
//     Module/loader/program-verification path links and returns a clean Error (not a crash)
//     for a missing file. Same "the archive is symbol-complete" gate the WASM/Android legs
//     use elsewhere in this repo.
//
// Exit 0 = pass, non-zero = fail.

#include <cstdio>

#include <executorch/runtime/platform/runtime.h>

static int fail(const char* msg) {
    std::fprintf(stderr, "FAIL: %s\n", msg);
    return 1;
}

#ifdef SMOKE_PTE

#include <cmath>
#include <vector>

#include <executorch/extension/module/module.h>
#include <executorch/extension/tensor/tensor.h>

using executorch::extension::Module;
using executorch::extension::make_tensor_ptr;

// Checkpoints to stderr (flushed) so we can localize an ExecuTorch ET_CHECK/abort even when
// the runtime is built with logging compiled out (the abort otherwise produces no output).
#define CK(msg) do { std::fprintf(stderr, "[smoke] " msg "\n"); std::fflush(stderr); } while (0)

int main() {
    CK("start");
    executorch::runtime::runtime_init();
    CK("runtime_init ok");

    Module module(SMOKE_PTE);
    CK("module constructed");
    const auto load_err = module.load();
    CK("module.load returned");
    if (load_err != executorch::runtime::Error::Ok) return fail("could not load add.pte");

    auto a = make_tensor_ptr({3}, std::vector<float>{1.0f, 2.0f, 3.0f});
    auto b = make_tensor_ptr({3}, std::vector<float>{2.0f, 3.0f, 4.0f});
    CK("inputs built; calling forward");

    auto result = module.forward({a, b});
    CK("forward returned");
    if (!result.ok()) return fail("forward() failed");

    const auto out = result->at(0).toTensor();
    if (out.numel() != 3) return fail("unexpected output size");

    const float* d = out.const_data_ptr<float>();
    const float expected[3] = {3.0f, 5.0f, 7.0f};
    for (int i = 0; i < 3; ++i)
        if (std::fabs(d[i] - expected[i]) > 1e-4f) return fail("a + b mismatch");

    std::printf("sum={%.1f,%.1f,%.1f} (expected {3,5,7}) — model load+run OK\n", d[0], d[1], d[2]);
    std::printf("PASS\n");
    return 0;
}

#else  // link + runtime-init only

#include <executorch/extension/module/module.h>

using executorch::extension::Module;

int main() {
    executorch::runtime::runtime_init();

    // Loading a path that does not exist must fail cleanly (not crash): this exercises the
    // Module -> data-loader -> program-verification call chain, proving those archives link.
    Module module("__anira_executorch_no_such_model__.pte");
    if (module.load() == executorch::runtime::Error::Ok)
        return fail("expected load() of a missing .pte to fail");

    std::printf("runtime initialized; Module/loader/verification link OK (no wheel -> link smoke)\n");
    std::printf("PASS\n");
    return 0;
}

#endif
