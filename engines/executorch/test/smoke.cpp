// ExecuTorch smoke test: validates a packaged ExecuTorch runtime (headers + the merged static
// archive). Links lib/libexecutorch.a on demand, with no force-load — the same way anira
// links it — so a real model run here is the proof that the kernel/backend registrations
// merge-static.sh pre-linked into the archive actually fire (a dropped registration still
// links; it fails at execute).
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
#include <cstring>
#include <string>

#include <executorch/runtime/backend/interface.h>
#include <executorch/runtime/platform/runtime.h>

static int fail(const char* msg) {
    std::fprintf(stderr, "FAIL: %s\n", msg);
    return 1;
}

// Variant guard, asked of the runtime's backend registry after runtime_init(): a -gpu package
// must register every delegate it claims (SMOKE_GPU_BACKENDS, comma-separated, set by the test
// CMakeLists) and a default package must register NONE of the GPU delegates — GPU is always a
// separate archive, and a CPU build under a -gpu name must fail here, not at a user's.
static int check_variant() {
    using executorch::runtime::get_backend_class;
    static const char* const kGpuBackends[] = {"CoreMLBackend", "MPSBackend", "MLXBackend", "VulkanBackend"};
#ifdef SMOKE_GPU_BACKENDS
    std::string list = SMOKE_GPU_BACKENDS;
    for (size_t pos = 0; pos <= list.size();) {
        size_t end = list.find(',', pos); if (end == std::string::npos) end = list.size();
        std::string name = list.substr(pos, end - pos);
        if (!name.empty()) {
            if (get_backend_class(name.c_str()) == nullptr) {
                std::fprintf(stderr, "FAIL: -gpu package does not register %s — built CPU-only?\n", name.c_str());
                return 1;
            }
            std::printf("delegate registered: %s\n", name.c_str());
        }
        pos = end + 1;
    }
#else
    for (const char* name : kGpuBackends) {
        if (get_backend_class(name) != nullptr) {
            std::fprintf(stderr, "FAIL: default (CPU) package registers %s — GPU must be a separate -gpu archive\n", name);
            return 1;
        }
    }
    std::printf("no GPU delegate registered (CPU package)\n");
#endif
    return 0;
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
    if (check_variant() != 0) return 1;

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
    if (check_variant() != 0) return 1;

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
