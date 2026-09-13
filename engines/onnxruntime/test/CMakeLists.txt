cmake_minimum_required(VERSION 3.22)
project(onnx_smoke LANGUAGES CXX)

# Consumes the PACKAGED onnxruntime archive exactly as anira does: CMAKE_PREFIX_PATH points at
# the staging tree (passed by the smoke action); we find the headers + the bundled lib and link
# smoke.cpp against it. Linking proves the static archive is symbol-complete; ctest runs a real
# forward pass (add.onnx: y = x + x, {1,2,3} -> {2,4,6}). Driven by .github/actions/smoke.

set(SMOKE_KIND "static" CACHE STRING "static | shared")
set(SMOKE_VARIANT "" CACHE STRING "expected package variant: '' (cpu) | gpu | cuda")

find_path(ORT_INC NAMES onnxruntime_cxx_api.h REQUIRED)
find_library(ORT_LIB NAMES onnxruntime REQUIRED)   # static .a/.lib, or shared .dylib/.so/import-.lib
get_filename_component(ORT_LIBDIR "${ORT_LIB}" DIRECTORY)

# False-green guards: a variant package that lost its accelerator must FAIL here, not
# quietly pass the CPU smoke (round 1 shipped CPU builds under -gpu names when the
# flavor arg was dropped — see cmake/ExternalEngine.cmake).
if(SMOKE_VARIANT STREQUAL "gpu"
   AND NOT EXISTS "${ORT_INC}/coreml_provider_factory.h"
   AND NOT EXISTS "${ORT_INC}/dml_provider_factory.h")
  message(FATAL_ERROR "-gpu package ships no GPU EP provider header — built CPU-only?")
endif()
if(SMOKE_VARIANT STREQUAL "cuda")
  file(GLOB _cuda_ep "${ORT_LIBDIR}/*onnxruntime_providers_cuda*")
  if(NOT _cuda_ep)
    message(FATAL_ERROR "-cuda package ships no CUDA execution provider library — plain repackage?")
  endif()
endif()

add_executable(smoke smoke.cpp)
target_include_directories(smoke PRIVATE "${ORT_INC}")
target_link_libraries(smoke PRIVATE "${ORT_LIB}")
target_compile_features(smoke PRIVATE cxx_std_17)

# GPU variant packages advertise their EP via the provider header they ship
# (CPU-only packages don't carry these headers) — the smoke keys its extra
# EP forward pass on that, exactly how anira should detect the variant.
if(EXISTS "${ORT_INC}/coreml_provider_factory.h")
  target_compile_definitions(smoke PRIVATE SMOKE_HAS_COREML)
endif()
if(EXISTS "${ORT_INC}/dml_provider_factory.h")
  target_compile_definitions(smoke PRIVATE SMOKE_HAS_DML)
  # d3d12/dxgi for the explicit WARP-device fallback (GPU-less runners); DirectML.dll
  # itself is resolved at runtime from the package (no import lib shipped).
  target_link_libraries(smoke PRIVATE d3d12 dxgi)
endif()

if(SMOKE_KIND STREQUAL "static")
  find_package(Threads REQUIRED)
  target_link_libraries(smoke PRIVATE Threads::Threads)
  if(WIN32)
    target_link_libraries(smoke PRIVATE advapi32)            # cpuinfo's RegGetValueW
  elseif(APPLE)
    target_link_libraries(smoke PRIVATE "-framework Foundation" "-framework CoreFoundation")
    # gpu variant: the static bundle contains the CoreML EP -> consumers must add the
    # framework — this documents anira's required link line for the -gpu package.
    if(EXISTS "${ORT_INC}/coreml_provider_factory.h")
      target_link_libraries(smoke PRIVATE "-framework CoreML")
    endif()
  else()
    target_link_libraries(smoke PRIVATE ${CMAKE_DL_LIBS} m rt) # Linux
  endif()
endif()

# The static lib is built with the dynamic CRT (/MD|/MDd) — the smoke must match (else LNK2038).
if(MSVC)
  set_property(TARGET smoke PROPERTY MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>DLL")
endif()

# Shared libs load from the staging lib dir at runtime (rpath on unix; Windows copies DLLs).
set_target_properties(smoke PROPERTIES BUILD_WITH_INSTALL_RPATH TRUE INSTALL_RPATH "${ORT_LIBDIR}")

enable_testing()
add_test(NAME smoke COMMAND smoke "${CMAKE_CURRENT_SOURCE_DIR}/add.onnx")
