// LiteRT smoke test: validates a packaged libtensorflowlite_c (headers + lib).
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

// Flattened path that anira uses (TFLiteProcessor.h): #include <tensorflow/lite/c_api.h>
#include "tensorflow/lite/c_api.h"

static int fail(const char* msg) {
    std::fprintf(stderr, "FAIL: %s\n", msg);
    return 1;
}

int main(int argc, char** argv) {
    if (argc < 2) return fail("usage: smoke <add.bin>");

    TfLiteModel* model = TfLiteModelCreateFromFile(argv[1]);
    if (!model) return fail("could not load model");

    TfLiteInterpreterOptions* opts = TfLiteInterpreterOptionsCreate();
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

    std::printf("input={%.1f,%.1f} output={%.4f,%.4f} expected={3.0,9.0}\n",
                input[0], input[1], output[0], output[1]);

    TfLiteInterpreterDelete(interp);
    TfLiteInterpreterOptionsDelete(opts);
    TfLiteModelDelete(model);

    const float expected[2] = {3.f, 9.f};
    for (int i = 0; i < 2; ++i)
        if (std::fabs(output[i] - expected[i]) > 1e-4f) return fail("output mismatch");

    std::printf("PASS\n");
    return 0;
}
