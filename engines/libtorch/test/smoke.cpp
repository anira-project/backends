// LibTorch smoke test: validates a packaged libtorch (headers + libs + Torch CMake
// package). Builds via find_package(Torch) — the same path anira uses — then runs a
// couple of real ops on the CPU and checks the exact results.
//
//   a = {1,2,3}, b = {2,3,4}
//   a + b        -> {3,5,7}
//   dot(a, b)    -> 1*2 + 2*3 + 3*4 = 20
//
// Linking + loading libtorch here is the real proof the packaged tree is complete
// (TorchConfig.cmake resolves, the shared libs load, symbols are present).
//
// Exit 0 = pass, non-zero = fail.

#include <torch/torch.h>

#include <cmath>
#include <cstdio>

static int fail(const char* msg) {
    std::fprintf(stderr, "FAIL: %s\n", msg);
    return 1;
}

int main() {
    torch::manual_seed(0);

    auto a = torch::tensor({1.0f, 2.0f, 3.0f});
    auto b = torch::tensor({2.0f, 3.0f, 4.0f});

    auto sum = a + b;
    auto expected_sum = torch::tensor({3.0f, 5.0f, 7.0f});
    if (!torch::allclose(sum, expected_sum)) return fail("a + b mismatch");

    auto dot = torch::dot(a, b).item<float>();
    std::printf("sum={%.1f,%.1f,%.1f} dot=%.1f (expected {3,5,7} / 20)\n",
                sum[0].item<float>(), sum[1].item<float>(), sum[2].item<float>(), dot);
    if (std::fabs(dot - 20.0f) > 1e-4f) return fail("dot mismatch");

#ifdef SMOKE_EXPECT_MPS
    // macOS arm64 -gpu variant (USE_MPS=1, docs/gpu-support.md): is_available() only
    // returns true when the backend is compiled in AND a Metal device exists — both
    // hold on the arm64 macOS runners, so a false here means the package lost MPS.
    if (!torch::mps::is_available()) return fail("MPS not available in the -gpu package");
    auto sum_mps = (a.to(torch::kMPS) + b.to(torch::kMPS)).to(torch::kCPU);
    if (!torch::allclose(sum_mps, expected_sum)) return fail("a + b on MPS mismatch");
    std::printf("MPS OK: a + b on Metal = {%.1f,%.1f,%.1f}\n",
                sum_mps[0].item<float>(), sum_mps[1].item<float>(), sum_mps[2].item<float>());
#elif defined(__APPLE__)
    // Default (CPU-only) macOS package: MPS must NOT be present.
    if (torch::mps::is_available()) return fail("CPU-only package unexpectedly has MPS — GPU belongs in the -gpu variant");
#endif

    std::printf("PASS\n");
    return 0;
}
