// ONNX Runtime smoke test: validates a packaged onnxruntime (headers + lib).
//
// Links the lib (the real proof it's symbol-complete), then — given a model path —
// loads a tiny model and runs a real FORWARD PASS, exercising the full inference
// path (session, MLAS kernels, the Add op). The bundled test/add.onnx computes
// y = x + x, so x = {1,2,3} must yield y = {2,4,6}.
//
// Usage: smoke <model.onnx>   (no arg = link/init check only)
// exit 0 = pass, non-zero = fail.

#include <cstdio>
#include <cmath>
#include <fstream>
#include <iterator>
#include <vector>

#include "onnxruntime_cxx_api.h"

int main(int argc, char** argv) {
    try {
        Ort::Env env(ORT_LOGGING_LEVEL_WARNING, "smoke");
        std::printf("ONNX Runtime version: %s\n", Ort::GetVersionString().c_str());

        if (argc < 2) {  // link + runtime-init only (cross-compiled targets that can't run a model)
            std::printf("env OK (no model arg)\n");
            return 0;
        }

        // Read the model into memory so the path is plain char* on every OS
        // (avoids ORTCHAR_T/wchar_t differences in the Session path constructor).
        std::ifstream f(argv[1], std::ios::binary);
        if (!f) { std::fprintf(stderr, "FAIL: cannot open model %s\n", argv[1]); return 1; }
        std::vector<char> model((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
        if (model.empty()) { std::fprintf(stderr, "FAIL: empty model\n"); return 1; }

        Ort::SessionOptions opts;
        Ort::Session session(env, model.data(), model.size(), opts);

        std::vector<float> x = {1.f, 2.f, 3.f};
        std::vector<int64_t> shape = {3};
        Ort::MemoryInfo mem = Ort::MemoryInfo::CreateCpu(OrtArenaAllocator, OrtMemTypeDefault);
        Ort::Value in = Ort::Value::CreateTensor<float>(mem, x.data(), x.size(), shape.data(), shape.size());

        const char* in_names[]  = {"x"};
        const char* out_names[] = {"y"};
        auto outs = session.Run(Ort::RunOptions{nullptr}, in_names, &in, 1, out_names, 1);

        const float* y = outs[0].GetTensorData<float>();
        const float expect[3] = {2.f, 4.f, 6.f};
        for (int i = 0; i < 3; ++i) {
            if (std::fabs(y[i] - expect[i]) > 1e-5f) {
                std::fprintf(stderr, "FAIL: y[%d]=%g, expected %g\n", i, y[i], expect[i]);
                return 1;
            }
        }
        std::printf("forward pass OK: y = {%g, %g, %g}\n", y[0], y[1], y[2]);
        std::printf("PASS\n");
        return 0;
    } catch (const Ort::Exception& e) {
        std::fprintf(stderr, "FAIL: %s\n", e.what());
        return 1;
    }
}
