cmake_minimum_required(VERSION 3.22)
project(tflite_smoke LANGUAGES CXX)

# Consumes the PACKAGED tflite archive exactly as anira does: CMAKE_PREFIX_PATH points at the
# staging tree (passed by the smoke action); we find the headers + the bundled lib and link
# smoke.cpp against it. Linking proves the archive is symbol-complete; ctest runs a real
# forward pass (add.bin: {1,3} -> {3,9}). Driven by the .github/actions/smoke verb.

set(SMOKE_KIND "static" CACHE STRING "static | shared")
set(SMOKE_VARIANT "" CACHE STRING "expected package variant: '' (cpu) | gpu")

find_path(TFLITE_INC NAMES tensorflow/lite/c_api.h REQUIRED)
find_library(TFLITE_LIB NAMES tensorflowlite_c REQUIRED)   # static .a/.lib, or shared .dylib/.so/import-.lib
get_filename_component(TFLITE_LIBDIR "${TFLITE_LIB}" DIRECTORY)

add_executable(smoke smoke.cpp)
target_include_directories(smoke PRIVATE "${TFLITE_INC}")
target_link_libraries(smoke PRIVATE "${TFLITE_LIB}")
target_compile_features(smoke PRIVATE cxx_std_17)

# Apple -gpu variant: the package ships the Metal GPU delegate — detected (like the ORT
# EPs) by the header it ships. The smoke then runs the forward pass through the delegate
# too. False-green guard: a -gpu package without the header means the delegate got lost.
if(SMOKE_VARIANT STREQUAL "gpu" AND NOT EXISTS "${TFLITE_INC}/tensorflow/lite/delegates/gpu/metal_delegate.h")
  message(FATAL_ERROR "-gpu package ships no Metal delegate header — built CPU-only?")
endif()
if(EXISTS "${TFLITE_INC}/tensorflow/lite/delegates/gpu/metal_delegate.h")
  target_compile_definitions(smoke PRIVATE SMOKE_HAS_METAL)
  # metal_delegate.h #imports <Metal/Metal.h> (Objective-C) unconditionally, so any TU
  # that includes it — a consumer's too — must be Objective-C++.
  enable_language(OBJCXX)
  set_source_files_properties(smoke.cpp PROPERTIES LANGUAGE OBJCXX)
  # Both kinds carry the delegate inside the one library (static: merged by the bundle
  # step; shared: force-loaded into the dylib with _TFLGpuDelegate* exported) — nothing
  # extra to link beyond the Apple frameworks.
  target_link_libraries(smoke PRIVATE "-framework Metal" "-framework Foundation" "-framework CoreFoundation")
endif()

if(SMOKE_KIND STREQUAL "static")
  # The C header drops __declspec(dllimport) under this define (Windows; no-op elsewhere).
  target_compile_definitions(smoke PRIVATE TFL_STATIC_LIBRARY_BUILD)
  find_package(Threads REQUIRED)
  target_link_libraries(smoke PRIVATE Threads::Threads)
  if(WIN32)
    target_link_libraries(smoke PRIVATE advapi32)           # cpuinfo's RegGetValueW
  elseif(NOT APPLE)
    target_link_libraries(smoke PRIVATE ${CMAKE_DL_LIBS} m) # Linux
  endif()
endif()

# The static lib is built with the dynamic CRT (/MD|/MDd) — the smoke must match (else LNK2038).
if(MSVC)
  set_property(TARGET smoke PROPERTY MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>DLL")
endif()

# Shared libs load from the staging lib dir at runtime (rpath on unix; Windows copies DLLs).
set_target_properties(smoke PROPERTIES BUILD_WITH_INSTALL_RPATH TRUE INSTALL_RPATH "${TFLITE_LIBDIR}")

# add.bin — the tiny TFLite test model at the pinned version (the archive ships no model).
file(STRINGS "${CMAKE_CURRENT_SOURCE_DIR}/../VERSION" TFLITE_VERSION)
string(STRIP "${TFLITE_VERSION}" TFLITE_VERSION)
set(MODEL "${CMAKE_BINARY_DIR}/add.bin")
if(NOT EXISTS "${MODEL}")
  file(DOWNLOAD
    "https://raw.githubusercontent.com/tensorflow/tensorflow/v${TFLITE_VERSION}/tensorflow/lite/testdata/add.bin"
    "${MODEL}" STATUS _dl)
  list(GET _dl 0 _code)
  if(NOT _code EQUAL 0)
    message(FATAL_ERROR "add.bin download failed: ${_dl}")
  endif()
endif()

enable_testing()
add_test(NAME smoke COMMAND smoke "${MODEL}")
