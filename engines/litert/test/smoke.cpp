// LiteRT native C API smoke: link libLiteRt and exercise the C API entry point —
// create + destroy a LiteRtEnvironment (no model needed). The link proves the packaged
// lib is symbol-complete (LiteRt* symbols resolve); the run proves it loads + initializes.
// (A full forward pass — LiteRtCreateCompiledModel + LiteRtRunCompiledModel on a .tflite —
// comes once the per-platform Bazel build is green.)
//
// Usage: smoke   (exit 0 = pass)
#include <cstdio>
#include "litert/c/litert_common.h"
#include "litert/c/litert_environment.h"

int main() {
    LiteRtEnvironment env = nullptr;
    LiteRtStatus s = LiteRtCreateEnvironment(/*num_options=*/0, /*options=*/nullptr, &env);
    if (s != kLiteRtStatusOk || env == nullptr) {
        std::printf("FAIL: LiteRtCreateEnvironment status=%d\n", static_cast<int>(s));
        return 1;
    }
    LiteRtDestroyEnvironment(env);
    std::printf("PASS: LiteRt environment create/destroy OK\n");
    return 0;
}
