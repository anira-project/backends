cmake_minimum_required(VERSION 3.25)

# Root orchestrator for every backend. ONE entry point — `cmake --preset <preset>` —
# builds (or repackages) any engine for any platform; the preset (see CMakePresets.json)
# selects the engine via BACKENDS_ENGINE and carries all build params. Then:
#   cmake --preset  <preset>
#   cmake --build   build/<preset>
#   cmake --install build/<preset> --prefix staging/<name>
# produces a uniform install tree for every engine.
#
#   tflite      — native CMake build (add_subdirectory): legacy TFLite C API (tensorflowlite_c).
#   onnxruntime — driven via engines/onnxruntime/stage.sh (build.py + bundle, or repackage).
#   libtorch    — driven via engines/libtorch/stage.sh   (build_libtorch.py, or repackage).
#   litert      — driven via engines/litert/stage.sh      (Bazel): LiteRT native C API (libLiteRt).
#   executorch  — driven via engines/executorch/stage.sh  (CMake): static CPU+XNNPACK PyTorch
#                 on-device runtime, consumed via find_package(executorch CONFIG).
# The orchestrated engines use their own build systems for cross-compilation; the root
# CMake is a uniform launcher + staging contract, not a CMake build of those engines.

set(BACKENDS_ENGINE "" CACHE STRING "Engine to build: tflite | onnxruntime | libtorch | litert | executorch")
set_property(CACHE BACKENDS_ENGINE PROPERTY STRINGS tflite onnxruntime libtorch litert executorch)

if(NOT BACKENDS_ENGINE)
  project(anira-backends NONE)
  message(FATAL_ERROR
    "BACKENDS_ENGINE is not set. Use a preset, e.g.\n"
    "  cmake --preset tflite-macos-arm64-static\n"
    "  cmake --preset onnx-linux-x86_64-static\n"
    "  cmake --preset libtorch-macos-arm64-shared\n"
    "  cmake --preset litert-macos-arm64-shared\n"
    "  cmake --preset executorch-macos-arm64-static")
endif()

if(BACKENDS_ENGINE STREQUAL "tflite")
  project(anira-backends LANGUAGES C CXX)
  add_subdirectory(engines/tflite)
elseif(BACKENDS_ENGINE STREQUAL "onnxruntime" OR BACKENDS_ENGINE STREQUAL "libtorch"
       OR BACKENDS_ENGINE STREQUAL "litert" OR BACKENDS_ENGINE STREQUAL "executorch")
  project(anira-backends NONE)
  include(cmake/ExternalEngine.cmake)
else()
  project(anira-backends NONE)
  message(FATAL_ERROR "Unknown BACKENDS_ENGINE='${BACKENDS_ENGINE}' (expected tflite|onnxruntime|libtorch|litert|executorch)")
endif()
