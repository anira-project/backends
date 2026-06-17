// LiteRT native C API smoke: link libLiteRt and exercise the real consumption path —
// create an environment, LOAD a .tflite model (both from file and from a memory buffer),
// and COMPILE it for the CPU accelerator. The link proves the packaged lib is symbol-complete;
// the run proves the packaged headers match the binary's ABI and that model loading works.
//
// This guards against a header/binary version skew: LiteRtCreateModelFrom{File,Buffer} gained a
// leading LiteRtEnvironment parameter upstream, so headers from a different commit than the lib
// silently mis-shift the arguments — model load then opens '' (status 500) or segfaults. Env
// create/destroy alone does NOT catch that; loading + compiling a real model does.
//
// (Numerical correctness of the forward pass is validated end-to-end in anira's test suite.)
//
// Usage: smoke <path/to/model.tflite>   (exit 0 = pass)
#include <cstdio>
#include <fstream>
#include <vector>

#include "litert/c/litert_common.h"
#include "litert/c/litert_environment.h"
#include "litert/c/litert_model.h"
#include "litert/c/litert_options.h"
#include "litert/c/litert_compiled_model.h"

static int fail(const char* what, LiteRtStatus s) {
    std::printf("FAIL: %s (status=%d)\n", what, static_cast<int>(s));
    return 1;
}

int main(int argc, char** argv) {
    if (argc < 2) { std::printf("usage: smoke <model.tflite>\n"); return 1; }
    const char* path = argv[1];

    LiteRtEnvironment env = nullptr;
    LiteRtStatus s = LiteRtCreateEnvironment(/*num_options=*/0, /*options=*/nullptr, &env);
    if (s != kLiteRtStatusOk || env == nullptr) return fail("LiteRtCreateEnvironment", s);

    // 1) Load from file.
    LiteRtModel model_file = nullptr;
    s = LiteRtCreateModelFromFile(env, path, &model_file);
    if (s != kLiteRtStatusOk || model_file == nullptr) return fail("LiteRtCreateModelFromFile", s);

    // 2) Load the same bytes from a memory buffer (must outlive the model).
    std::ifstream f(path, std::ios::binary | std::ios::ate);
    if (!f) { std::printf("FAIL: cannot read %s\n", path); return 1; }
    const std::streamsize n = f.tellg();
    f.seekg(0);
    std::vector<char> buf(static_cast<size_t>(n));
    f.read(buf.data(), n);
    LiteRtModel model_buf = nullptr;
    s = LiteRtCreateModelFromBuffer(env, buf.data(), static_cast<size_t>(n), &model_buf);
    if (s != kLiteRtStatusOk || model_buf == nullptr) return fail("LiteRtCreateModelFromBuffer", s);

    // 3) Compile (CPU) — exercises the rest of the model-consumption ABI.
    LiteRtOptions opts = nullptr;
    s = LiteRtCreateOptions(&opts);
    if (s != kLiteRtStatusOk) return fail("LiteRtCreateOptions", s);
    s = LiteRtSetOptionsHardwareAccelerators(opts, kLiteRtHwAcceleratorCpu);
    if (s != kLiteRtStatusOk) return fail("LiteRtSetOptionsHardwareAccelerators", s);
    LiteRtCompiledModel compiled = nullptr;
    s = LiteRtCreateCompiledModel(env, model_file, opts, &compiled);
    if (s != kLiteRtStatusOk || compiled == nullptr) return fail("LiteRtCreateCompiledModel", s);

    LiteRtDestroyCompiledModel(compiled);
    LiteRtDestroyOptions(opts);
    LiteRtDestroyModel(model_buf);
    LiteRtDestroyModel(model_file);
    LiteRtDestroyEnvironment(env);

    std::printf("PASS: LiteRt env + model load (file+buffer) + CPU compile OK\n");
    return 0;
}
