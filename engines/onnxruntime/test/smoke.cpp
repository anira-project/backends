// ONNX Runtime smoke test: validates a packaged static onnxruntime (headers + lib).
//
// Links the bundled static lib (the real proof it's symbol-complete), gets the C API,
// and creates + releases an OrtEnv (exercises runtime init). A model forward pass is a
// follow-up (needs a tiny vendored .onnx).
//
// exit 0 = pass, non-zero = fail.

#include <cstdio>

#include "onnxruntime_c_api.h"

static int fail(const char* msg) {
    std::fprintf(stderr, "FAIL: %s\n", msg);
    return 1;
}

int main() {
    const OrtApiBase* base = OrtGetApiBase();
    if (!base) return fail("OrtGetApiBase returned null");
    std::printf("ONNX Runtime version: %s\n", base->GetVersionString());

    const OrtApi* api = base->GetApi(ORT_API_VERSION);
    if (!api) return fail("GetApi returned null");

    OrtEnv* env = nullptr;
    OrtStatus* status = api->CreateEnv(ORT_LOGGING_LEVEL_WARNING, "smoke", &env);
    if (status != nullptr) {
        std::fprintf(stderr, "FAIL: CreateEnv: %s\n", api->GetErrorMessage(status));
        api->ReleaseStatus(status);
        return 1;
    }
    if (!env) return fail("CreateEnv gave null env");
    api->ReleaseEnv(env);

    std::printf("PASS\n");
    return 0;
}
