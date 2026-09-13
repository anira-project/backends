cmake_minimum_required(VERSION 3.22)
project(litert_smoke LANGUAGES CXX)

# Consumes the PACKAGED LiteRT-native archive as anira would: CMAKE_PREFIX_PATH points at the
# staging tree; we find the litert/c headers + libLiteRt and link smoke.cpp. Link proves the lib
# is symbol-complete; ctest runs the env create/destroy. Driven by .github/actions/smoke.

set(SMOKE_KIND "shared" CACHE STRING "static | shared")
set(SMOKE_VARIANT "" CACHE STRING "expected package variant: '' (cpu) | gpu")

find_path(LITERT_INC NAMES litert/c/litert_environment.h REQUIRED)
find_library(LITERT_LIB NAMES LiteRt REQUIRED)          # static .a, or shared .dylib/.so/import-.lib
get_filename_component(LITERT_LIBDIR "${LITERT_LIB}" DIRECTORY)

# Variant guard (false-green protection, like the other engines): a -gpu package must ship the
# GPU accelerator shared object next to libLiteRt — the runtime dlopens it at compile time for
# kLiteRtHwAcceleratorGpu — and a CPU package must not. The smoke then asks the runtime: a -gpu
# package must compile the model FULLY accelerated on the GPU, a CPU package must not be able to.
file(GLOB _litert_accels "${LITERT_LIBDIR}/libLiteRt*Accelerator.*")
if(SMOKE_VARIANT STREQUAL "gpu" AND NOT _litert_accels)
  message(FATAL_ERROR "-gpu package ships no libLiteRt*Accelerator next to libLiteRt — plain repackage?")
endif()
if(SMOKE_VARIANT STREQUAL "" AND _litert_accels)
  message(FATAL_ERROR "default (CPU) package ships a GPU accelerator (${_litert_accels}) — GPU must be a separate -gpu archive")
endif()

add_executable(smoke smoke.cpp)
target_include_directories(smoke PRIVATE "${LITERT_INC}")
if(SMOKE_VARIANT STREQUAL "gpu")
  target_compile_definitions(smoke PRIVATE SMOKE_GPU=1)
endif()
target_link_libraries(smoke PRIVATE "${LITERT_LIB}")
target_compile_features(smoke PRIVATE cxx_std_17)

# Static libLiteRt.a is the merged transitive closure (absl, tflite, …) — the consumer supplies
# only the external system deps those objects reference.
if(SMOKE_KIND STREQUAL "static")
  find_package(Threads REQUIRED)
  target_link_libraries(smoke PRIVATE Threads::Threads)
  if(WIN32)
    target_link_libraries(smoke PRIVATE advapi32)            # cpuinfo's RegGetValueW
  elseif(APPLE)
    # Foundation/CoreFoundation for absl/cpuinfo; Metal+Accelerate are referenced by the runtime's
    # (CPU-unused) GPU/BLAS objects pulled in transitively.
    target_link_libraries(smoke PRIVATE "-framework Foundation" "-framework CoreFoundation"
                                        "-framework Metal" "-framework Accelerate")
  else()
    target_link_libraries(smoke PRIVATE ${CMAKE_DL_LIBS} m rt stdc++fs)  # stdc++fs: std::filesystem
  endif()
endif()

if(MSVC)
  set_property(TARGET smoke PROPERTY MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>DLL")
endif()

# Shared lib loads from the staging lib dir at runtime (rpath on unix; Windows copies the DLL).
set_target_properties(smoke PROPERTIES BUILD_WITH_INSTALL_RPATH TRUE INSTALL_RPATH "${LITERT_LIBDIR}")

# A tiny .tflite model for the load+compile smoke (LiteRT loads the .tflite flatbuffer like
# TFLite). Reuse TFLite's pinned add.bin test model — the LiteRt archive ships no model.
set(MODEL "${CMAKE_BINARY_DIR}/add.bin")
if(NOT EXISTS "${MODEL}")
  file(DOWNLOAD
    "https://raw.githubusercontent.com/tensorflow/tensorflow/v2.17.0/tensorflow/lite/testdata/add.bin"
    "${MODEL}" STATUS _dl)
  list(GET _dl 0 _code)
  if(NOT _code EQUAL 0)
    message(FATAL_ERROR "add.bin download failed: ${_dl}")
  endif()
endif()

enable_testing()
# argv[2]: the package lib dir — handed to the runtime as kLiteRtEnvOptionTagRuntimeLibraryDir,
# where it looks for the GPU accelerator (the consumer does the same with its install dir).
add_test(NAME smoke COMMAND smoke "${MODEL}" "${LITERT_LIBDIR}")
