// LiteRT native C API smoke: link libLiteRt and exercise the real consumption path —
// create an environment, LOAD a .tflite model (both from file and from a memory buffer),
// COMPILE it and RUN a forward pass (add.bin: y = 3x, {1,3} -> {3,9}). The link proves the
// packaged lib is symbol-complete; the run proves the packaged headers match the binary's ABI
// and that model loading, compilation and inference work.
//
// This guards against a header/binary version skew: LiteRtCreateModelFrom{File,Buffer} gained a
// leading LiteRtEnvironment parameter upstream, so headers from a different commit than the lib
// silently mis-shift the arguments — model load then opens '' (status 500) or segfaults. Env
// create/destroy alone does NOT catch that; loading + compiling a real model does.
//
// -gpu variant (SMOKE_GPU): the package ships upstream's GPU accelerator shared object beside
// libLiteRt (libLiteRtWebGpuAccelerator on Linux/Windows, libLiteRtMetalAccelerator on macOS);
// the runtime dlopens it from kLiteRtEnvOptionTagRuntimeLibraryDir (argv[2], the package lib
// dir) when a model is compiled for kLiteRtHwAcceleratorGpu. The smoke runs the forward pass
// again on the GPU and asserts the compiled model is FULLY accelerated — a CPU build under a
// -gpu name fails here. A CPU package asserts the opposite: compiling for the GPU must not
// yield a fully accelerated model (no accelerator is there to load). On GPU-less Linux CI
// runners the smoke action provides a software Vulkan ICD (Mesa lavapipe) for the WebGPU
// accelerator; macOS runs Metal natively.
//
// Usage: smoke <path/to/model.tflite> [lib-dir]   (exit 0 = pass)
#include <cmath>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <vector>

#include "litert/c/litert_common.h"
#include "litert/c/litert_compiled_model.h"
#include "litert/c/litert_environment.h"
#include "litert/c/litert_environment_options.h"
#include "litert/c/litert_layout.h"
#include "litert/c/litert_model.h"
#include "litert/c/litert_model_types.h"
#include "litert/c/litert_options.h"
#include "litert/c/litert_tensor_buffer.h"
#include "litert/c/litert_tensor_buffer_requirements.h"

static int fail(const char* what, LiteRtStatus s) {
    std::printf("FAIL: %s (status=%d)\n", what, static_cast<int>(s));
    return 1;
}

// One forward pass of add.bin (input resized to [2]) compiled for `accel`. Sets *fully to the
// runtime's IsFullyAccelerated answer. Returns non-zero on any API failure or a wrong result.
static int run_pass(LiteRtEnvironment env, LiteRtModel model, LiteRtHwAcceleratorSet accel,
                    const char* label, bool* fully) {
    LiteRtOptions opts = nullptr;
    LiteRtStatus s = LiteRtCreateOptions(&opts);
    if (s != kLiteRtStatusOk) return fail("LiteRtCreateOptions", s);
    s = LiteRtSetOptionsHardwareAccelerators(opts, accel);
    if (s != kLiteRtStatusOk) return fail("LiteRtSetOptionsHardwareAccelerators", s);
    LiteRtCompiledModel compiled = nullptr;
    s = LiteRtCreateCompiledModel(env, model, opts, &compiled);
    if (s != kLiteRtStatusOk || compiled == nullptr) {
        std::printf("[%s] LiteRtCreateCompiledModel failed (status=%d)\n", label, static_cast<int>(s));
        LiteRtDestroyOptions(opts);
        *fully = false;
        return 2;  // "could not compile for this accelerator set" — meaningful for the CPU-package check
    }
    bool full = false;
    s = LiteRtCompiledModelIsFullyAccelerated(compiled, &full);
    if (s != kLiteRtStatusOk) return fail("LiteRtCompiledModelIsFullyAccelerated", s);
    *fully = full;

    // add.bin's input has a fixed [1] signature — size it to [2] the way the TFLite smoke does:
    // the NON-strict resize (the strict one refuses a non-dynamic dimension), then refresh the
    // output layouts with update_allocation so the output side follows the new shape.
    const int dims[1] = {2};
    s = LiteRtCompiledModelResizeInputTensorNonStrict(compiled, 0, 0, dims, 1);
    if (s != kLiteRtStatusOk) return fail("LiteRtCompiledModelResizeInputTensorNonStrict", s);
    LiteRtLayout out_layout;
    std::memset(&out_layout, 0, sizeof(out_layout));
    s = LiteRtGetCompiledModelOutputTensorLayouts(compiled, 0, 1, &out_layout, /*update_allocation=*/true);
    if (s != kLiteRtStatusOk) return fail("LiteRtGetCompiledModelOutputTensorLayouts", s);
    if (out_layout.rank != 1 || out_layout.dimensions[0] != 2) {
        std::printf("FAIL: [%s] output layout after resize is rank %u dims[0]=%d, expected [2]\n",
                    label, static_cast<unsigned>(out_layout.rank), out_layout.dimensions[0]);
        return 1;
    }

    LiteRtRankedTensorType ttype;
    std::memset(&ttype, 0, sizeof(ttype));
    ttype.element_type = kLiteRtElementTypeFloat32;
    ttype.layout.rank = 1;
    ttype.layout.dimensions[0] = 2;

    LiteRtTensorBufferRequirements in_req = nullptr, out_req = nullptr;
    s = LiteRtGetCompiledModelInputBufferRequirements(compiled, 0, 0, &in_req);
    if (s != kLiteRtStatusOk) return fail("LiteRtGetCompiledModelInputBufferRequirements", s);
    s = LiteRtGetCompiledModelOutputBufferRequirements(compiled, 0, 0, &out_req);
    if (s != kLiteRtStatusOk) return fail("LiteRtGetCompiledModelOutputBufferRequirements", s);
    LiteRtTensorBuffer in_buf = nullptr, out_buf = nullptr;
    s = LiteRtCreateManagedTensorBufferFromRequirements(env, &ttype, in_req, &in_buf);
    if (s != kLiteRtStatusOk) return fail("LiteRtCreateManagedTensorBufferFromRequirements(in)", s);
    s = LiteRtCreateManagedTensorBufferFromRequirements(env, &ttype, out_req, &out_buf);
    if (s != kLiteRtStatusOk) return fail("LiteRtCreateManagedTensorBufferFromRequirements(out)", s);

    void* p = nullptr;
    s = LiteRtLockTensorBuffer(in_buf, &p, kLiteRtTensorBufferLockModeWrite);
    if (s != kLiteRtStatusOk) return fail("LiteRtLockTensorBuffer(in)", s);
    const float input[2] = {1.f, 3.f};
    std::memcpy(p, input, sizeof(input));
    s = LiteRtUnlockTensorBuffer(in_buf);
    if (s != kLiteRtStatusOk) return fail("LiteRtUnlockTensorBuffer(in)", s);

    LiteRtTensorBuffer ins[1] = {in_buf}, outs[1] = {out_buf};
    s = LiteRtRunCompiledModel(compiled, 0, 1, ins, 1, outs);
    if (s != kLiteRtStatusOk) return fail("LiteRtRunCompiledModel", s);

    float output[2] = {0.f, 0.f};
    s = LiteRtLockTensorBuffer(out_buf, &p, kLiteRtTensorBufferLockModeRead);
    if (s != kLiteRtStatusOk) return fail("LiteRtLockTensorBuffer(out)", s);
    std::memcpy(output, p, sizeof(output));
    s = LiteRtUnlockTensorBuffer(out_buf);
    if (s != kLiteRtStatusOk) return fail("LiteRtUnlockTensorBuffer(out)", s);

    LiteRtDestroyTensorBuffer(in_buf);
    LiteRtDestroyTensorBuffer(out_buf);
    LiteRtDestroyCompiledModel(compiled);
    LiteRtDestroyOptions(opts);

    std::printf("[%s] input={%.1f,%.1f} output={%.4f,%.4f} expected={3.0,9.0} fully_accelerated=%d\n",
                label, input[0], input[1], output[0], output[1], full ? 1 : 0);
    const float expected[2] = {3.f, 9.f};
    for (int i = 0; i < 2; ++i)
        if (std::fabs(output[i] - expected[i]) > 1e-4f) { std::printf("FAIL: [%s] output mismatch\n", label); return 1; }
    return 0;
}

int main(int argc, char** argv) {
    if (argc < 2) { std::printf("usage: smoke <model.tflite> [lib-dir]\n"); return 1; }
    const char* path = argv[1];

    // Point the runtime's accelerator loader at the package lib dir (where a -gpu package
    // keeps its accelerator); harmless for a CPU package (nothing to find).
    std::vector<LiteRtEnvOption> env_opts;
    if (argc >= 3) {
        LiteRtEnvOption o;
        std::memset(&o, 0, sizeof(o));
        o.tag = kLiteRtEnvOptionTagRuntimeLibraryDir;
        o.value.type = kLiteRtAnyTypeString;
        o.value.str_value = argv[2];
        env_opts.push_back(o);
    }
    LiteRtEnvironment env = nullptr;
    LiteRtStatus s = LiteRtCreateEnvironment(static_cast<int>(env_opts.size()),
                                             env_opts.empty() ? nullptr : env_opts.data(), &env);
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

    // 3) CPU forward pass.
    bool fully = false;
    if (run_pass(env, model_file, kLiteRtHwAcceleratorCpu, "cpu", &fully) != 0) return 1;

    // 4) GPU: a -gpu package must run the graph fully on its accelerator; a CPU package must not.
    const int gpu_rc = run_pass(env, model_buf, kLiteRtHwAcceleratorGpu, "gpu", &fully);
#ifdef SMOKE_GPU
    if (gpu_rc != 0) { std::printf("FAIL: -gpu package could not compile/run on the GPU accelerator\n"); return 1; }
    if (!fully) { std::printf("FAIL: -gpu package did not fully accelerate the model on the GPU — accelerator not loaded?\n"); return 1; }
#else
    if (gpu_rc == 1) return 1;  // an API failure unrelated to accelerator absence
    if (gpu_rc == 0 && fully) { std::printf("FAIL: default (CPU) package ran fully GPU-accelerated — GPU must be a separate -gpu archive\n"); return 1; }
    std::printf("no GPU accelerator available (CPU package), as expected\n");
#endif

    LiteRtDestroyModel(model_buf);
    LiteRtDestroyModel(model_file);
    LiteRtDestroyEnvironment(env);

    std::printf("PASS: LiteRt env + model load (file+buffer) + compile + forward pass OK\n");
    return 0;
}
