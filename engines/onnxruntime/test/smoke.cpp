// ONNX Runtime smoke test: validates a packaged onnxruntime (headers + lib).
//
// Links the lib (the real proof it's symbol-complete), then — given a model path —
// loads a tiny model and runs a real FORWARD PASS, exercising the full inference
// path (session, MLAS kernels, the Add op). The bundled test/add.onnx computes
// y = x + x, so x = {1,2,3} must yield y = {2,4,6}.
//
// GPU variant packages (docs/gpu-support.md) run the forward pass a second time with
// their EP appended — CoreML (macOS -gpu) / DirectML (Windows -gpu) — proving the EP
// is linked, registers, and executes (nodes the EP can't take fall back to CPU).
// The extra pass is keyed on the provider header the package ships (SMOKE_HAS_COREML /
// SMOKE_HAS_DML from the CMakeLists); CPU-only packages run the CPU pass only.
//
// Usage: smoke <model.onnx>   (no arg = link/init check only)
// exit 0 = pass, non-zero = fail.

#include <cstdio>
#include <cmath>
#include <fstream>
#include <iterator>
#include <string>
#include <unordered_map>
#include <vector>

#include "onnxruntime_cxx_api.h"
#ifdef SMOKE_HAS_DML
#include <dxgi1_4.h>   // IDXGIFactory4::EnumWarpAdapter (WARP fallback on GPU-less runners)
#include "dml_provider_factory.h"
#endif

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

        auto run = [&](Ort::SessionOptions& opts, const char* label) -> int {
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
                    std::fprintf(stderr, "FAIL(%s): y[%d]=%g, expected %g\n", label, i, y[i], expect[i]);
                    return 1;
                }
            }
            std::printf("forward pass OK (%s): y = {%g, %g, %g}\n", label, y[0], y[1], y[2]);
            return 0;
        };

        Ort::SessionOptions cpu_opts;
        if (run(cpu_opts, "cpu")) return 1;

#ifdef SMOKE_HAS_COREML
        // macOS -gpu variant: prove the CoreML EP registers and runs.
        Ort::SessionOptions coreml_opts;
        coreml_opts.AppendExecutionProvider("CoreML", std::unordered_map<std::string, std::string>{});
        if (run(coreml_opts, "coreml")) return 1;
#endif

#ifdef SMOKE_HAS_DML
        // Windows -gpu variant: prove the DirectML EP registers and runs. The simple
        // device_id path deliberately skips software adapters (fails with C0262002 on
        // GPU-less CI runners), so fall back to an explicitly created WARP (software)
        // D3D12 device via the DML1 API. DML needs mem patterns off + sequential exec.
        {
            const OrtDmlApi* dml_api = nullptr;
            Ort::ThrowOnError(Ort::GetApi().GetExecutionProviderApi(
                "DML", ORT_API_VERSION, reinterpret_cast<const void**>(&dml_api)));

            Ort::SessionOptions dml_opts;
            dml_opts.DisableMemPattern();
            dml_opts.SetExecutionMode(ORT_SEQUENTIAL);
            OrtStatus* hw = dml_api->SessionOptionsAppendExecutionProvider_DML(dml_opts, 0);
            if (hw == nullptr) {
                if (run(dml_opts, "dml")) return 1;
            } else {
                std::fprintf(stderr, "note: no hardware D3D12 adapter (%s) -> WARP fallback\n",
                             Ort::GetApi().GetErrorMessage(hw));
                Ort::GetApi().ReleaseStatus(hw);

                IDXGIFactory4* factory = nullptr;
                if (FAILED(CreateDXGIFactory1(IID_PPV_ARGS(&factory))))
                    { std::fprintf(stderr, "FAIL: CreateDXGIFactory1\n"); return 1; }
                IDXGIAdapter* warp = nullptr;
                if (FAILED(factory->EnumWarpAdapter(IID_PPV_ARGS(&warp))))
                    { std::fprintf(stderr, "FAIL: EnumWarpAdapter\n"); return 1; }
                ID3D12Device* dev = nullptr;
                if (FAILED(D3D12CreateDevice(warp, D3D_FEATURE_LEVEL_11_0, IID_PPV_ARGS(&dev))))
                    { std::fprintf(stderr, "FAIL: D3D12CreateDevice(WARP)\n"); return 1; }

                // DMLCreateDevice lives in the DirectML.dll shipped in this package
                // (copied next to the smoke exe by the smoke action) — resolve it
                // dynamically so the smoke needs no DirectML import lib.
                HMODULE dml_mod = LoadLibraryW(L"DirectML.dll");
                if (!dml_mod) { std::fprintf(stderr, "FAIL: LoadLibrary(DirectML.dll)\n"); return 1; }
                using DMLCreateDeviceFn = HRESULT(WINAPI*)(ID3D12Device*, DML_CREATE_DEVICE_FLAGS, REFIID, void**);
                auto dml_create = reinterpret_cast<DMLCreateDeviceFn>(
                    reinterpret_cast<void*>(GetProcAddress(dml_mod, "DMLCreateDevice")));
                if (!dml_create) { std::fprintf(stderr, "FAIL: GetProcAddress(DMLCreateDevice)\n"); return 1; }
                IDMLDevice* dml_dev = nullptr;
                if (FAILED(dml_create(dev, DML_CREATE_DEVICE_FLAG_NONE, IID_PPV_ARGS(&dml_dev))))
                    { std::fprintf(stderr, "FAIL: DMLCreateDevice(WARP)\n"); return 1; }

                D3D12_COMMAND_QUEUE_DESC qd = {};
                qd.Type = D3D12_COMMAND_LIST_TYPE_DIRECT;
                ID3D12CommandQueue* queue = nullptr;
                if (FAILED(dev->CreateCommandQueue(&qd, IID_PPV_ARGS(&queue))))
                    { std::fprintf(stderr, "FAIL: CreateCommandQueue\n"); return 1; }

                Ort::SessionOptions warp_opts;
                warp_opts.DisableMemPattern();
                warp_opts.SetExecutionMode(ORT_SEQUENTIAL);
                Ort::ThrowOnError(dml_api->SessionOptionsAppendExecutionProvider_DML1(warp_opts, dml_dev, queue));
                if (run(warp_opts, "dml-warp")) return 1;
            }
        }
#endif

        std::printf("PASS\n");
        return 0;
    } catch (const Ort::Exception& e) {
        std::fprintf(stderr, "FAIL: %s\n", e.what());
        return 1;
    }
}
