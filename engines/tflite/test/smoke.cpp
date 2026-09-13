// TFLite smoke test: validates a packaged libtensorflowlite_c (headers + lib).
//
// Loads TFLite's tiny `add.bin` test model (a 3x model), runs one forward pass,
// and checks the exact output. Mirrors upstream tensorflow/lite/c/c_test.c:
//   input {1, 3}  ->  output {3, 9}.
//
// It's C++ (compiles the C API header in a C++ TU) so it also exercises the
// C++ link path. Linking the STATIC lib here is the real proof that the bundled
// archive is symbol-complete.
//
// Usage: smoke <path/to/add.bin>   (exit 0 = pass, non-zero = fail)

#include <cmath>
#include <cstdio>

// Desktop/Android packages use anira's flattened path (tensorflow/lite/c_api.h);
// the iOS prebuilt ships a framework (TensorFlowLiteC/c_api.h). Support both.
#if __has_include(<TensorFlowLiteC/c_api.h>)
#  include <TensorFlowLiteC/c_api.h>
#else
#  include "tensorflow/lite/c_api.h"
#endif
#ifdef SMOKE_HAS_METAL
#  include "tensorflow/lite/delegates/gpu/metal_delegate.h"
#endif
#ifdef SMOKE_HAS_GPU_DELEGATE_LINK
#  include "tensorflow/lite/delegates/gpu/delegate.h"
// Android -gpu (compile+link smoke, no GPU on the emulator): referencing the OpenCL delegate's
// entry point proves the package carries it — the link fails for a CPU build under a -gpu name.
__attribute__((used)) static TfLiteDelegate* (*const s_gpu_delegate_create)(const TfLiteGpuDelegateOptionsV2*) = &TfLiteGpuDelegateV2Create;
#endif

static int fail(const char* msg) {
    std::fprintf(stderr, "FAIL: %s\n", msg);
    return 1;
}

// One forward pass; with_metal adds the Metal GPU delegate (-gpu variant) so the
// pass actually executes on the GPU (add.bin's ADD op is delegate-supported).
static int run_pass(const char* model_path, bool with_metal, const char* label) {
    TfLiteModel* model = TfLiteModelCreateFromFile(model_path);
    if (!model) return fail("could not load model");

    TfLiteInterpreterOptions* opts = TfLiteInterpreterOptionsCreate();
    TfLiteDelegate* metal = nullptr;
#ifdef SMOKE_HAS_METAL
    if (with_metal) {
        metal = TFLGpuDelegateCreate(nullptr);
        if (!metal) return fail("TFLGpuDelegateCreate");
        TfLiteInterpreterOptionsAddDelegate(opts, metal);
    }
#else
    (void)with_metal;
#endif
    TfLiteInterpreter* interp = TfLiteInterpreterCreate(model, opts);
    if (!interp) return fail("could not create interpreter");

    // add.bin's input has an unspecified shape — size it to [2] before allocating.
    const int input_dims[1] = {2};
    if (TfLiteInterpreterResizeInputTensor(interp, 0, input_dims, 1) != kTfLiteOk) return fail("resize input");
    if (TfLiteInterpreterAllocateTensors(interp) != kTfLiteOk) return fail("allocate tensors");

    const float input[2] = {1.f, 3.f};
    TfLiteTensor* in = TfLiteInterpreterGetInputTensor(interp, 0);
    if (TfLiteTensorCopyFromBuffer(in, input, sizeof(input)) != kTfLiteOk) return fail("copy input");

    if (TfLiteInterpreterInvoke(interp) != kTfLiteOk) return fail("invoke");

    float output[2] = {0.f, 0.f};
    const TfLiteTensor* out = TfLiteInterpreterGetOutputTensor(interp, 0);
    if (TfLiteTensorCopyToBuffer(out, output, sizeof(output)) != kTfLiteOk) return fail("copy output");

    std::printf("[%s] input={%.1f,%.1f} output={%.4f,%.4f} expected={3.0,9.0}\n",
                label, input[0], input[1], output[0], output[1]);

    TfLiteInterpreterDelete(interp);
    TfLiteInterpreterOptionsDelete(opts);
    TfLiteModelDelete(model);
#ifdef SMOKE_HAS_METAL
    if (metal) TFLGpuDelegateDelete(metal);
#endif

    const float expected[2] = {3.f, 9.f};
    for (int i = 0; i < 2; ++i)
        if (std::fabs(output[i] - expected[i]) > 1e-4f) return fail("output mismatch");
    return 0;
}

int main(int argc, char** argv) {
    if (argc < 2) return fail("usage: smoke <add.bin>");

    if (run_pass(argv[1], false, "cpu")) return 1;
#ifdef SMOKE_HAS_METAL
    // -gpu variant: prove the Metal delegate creates, takes the graph, and executes.
    if (run_pass(argv[1], true, "metal")) return 1;
#endif

    std::printf("PASS\n");
    return 0;
}
