cmake_minimum_required(VERSION 3.16)

# Thin wrapper around upstream tensorflow/lite/c: fetch tensorflow at the pinned
# version, build `tensorflowlite_c`, install into anira's layout (include/ + lib/).
# Driven by CMakePresets.json (one preset per platform x shared/static).

file(STRINGS "${CMAKE_CURRENT_SOURCE_DIR}/VERSION" LITERT_VERSION)
string(STRIP "${LITERT_VERSION}" LITERT_VERSION)

project(litert-c LANGUAGES C CXX
        VERSION ${LITERT_VERSION}
        DESCRIPTION "TensorFlow Lite / LiteRT C API prebuilt for anira")

option(LITERT_BUILD_STATIC "Build a static archive instead of a shared library" OFF)

# TFLite uses C++20 features (e.g. designated initializers in core/c/operator.cc).
# clang/gcc accept these as an extension under C++17, but MSVC is strict and errors
# (C7555) — so require C++20 globally.
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# On Apple, CMAKE_SYSTEM_PROCESSOR stays the HOST arch even when targeting a
# different CMAKE_OSX_ARCHITECTURES (this isn't a "real" crosscompile, so CMake
# overwrites any cache value with the host). TFLite keys its x86-vs-ARM decisions
# on CMAKE_SYSTEM_PROCESSOR — e.g. fetching the NEON_2_SSE shim x86_64 needs —
# so force the normal variable to match the target arch before building TFLite.
if(APPLE AND CMAKE_OSX_ARCHITECTURES)
    set(CMAKE_SYSTEM_PROCESSOR "${CMAKE_OSX_ARCHITECTURES}")
endif()

# NOTE: old TFLite deps (FP16/psimd/…) need CMAKE_POLICY_VERSION_MINIMUM=3.5 under
# CMake 4+. It's set via the preset `environment` (not a cache var here) so the
# nested cmake download processes inherit it too.

# CPU-only: XNNPACK (SIMD CPU) on; GPU/NPU delegates off. Exception: Windows-on-ARM64
# with MSVC can't build XNNPACK's NEON microkernels (unresolved xnn_*_ukernel__neon*),
# so disable it there — TFLite falls back to its built-in kernels.
if(WIN32 AND CMAKE_SYSTEM_PROCESSOR MATCHES "ARM64|arm64|aarch64")
    set(TFLITE_ENABLE_XNNPACK OFF CACHE BOOL "" FORCE)
    message(STATUS "LiteRT: XNNPACK disabled on Windows/ARM64 (MSVC NEON microkernels unsupported)")
else()
    set(TFLITE_ENABLE_XNNPACK ON CACHE BOOL "" FORCE)
endif()
set(TFLITE_ENABLE_GPU OFF CACHE BOOL "" FORCE)

# Lib type uses upstream's own TFLITE_C_BUILD_SHARED_LIBS, not BUILD_SHARED_LIBS.
if(LITERT_BUILD_STATIC)
    # The static .a holds only C-API objects; transitive dep archives must be
    # merged in afterwards (shared/bundle-static.sh) to be usable.
    set(TFLITE_C_BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
else()
    set(TFLITE_C_BUILD_SHARED_LIBS ON CACHE BOOL "" FORCE)
endif()
message(STATUS "LiteRT ${LITERT_VERSION}: ${LITERT_BUILD_STATIC}=static")

# Windows: export DLL symbols so the .lib import library is usable.
set(CMAKE_WINDOWS_EXPORT_ALL_SYMBOLS ON CACHE BOOL "" FORCE)

# Force the dynamic CRT (/MD) across all TFLite targets + deps. Some deps default
# to the static CRT (/MT), which mixes libucrt.lib (static) with ucrt.lib (dynamic)
# and makes the static lib unlinkable by a normal /MD consumer app (LNK2005/LNK4098).
# /MD is the standard for a redistributable static lib. CMP0091=NEW (default at our
# cmake_minimum) makes CMAKE_MSVC_RUNTIME_LIBRARY authoritative.
if(MSVC)
    set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>DLL")
    # /FS (parallel-safe PDB writes, avoids C1041 in Debug) is injected via the CL
    # env var in CI — add_compile_options doesn't reach TFLite's nested FetchContent deps.
endif()

include(FetchContent)
FetchContent_Declare(
    tensorflow
    GIT_REPOSITORY https://github.com/tensorflow/tensorflow.git
    GIT_TAG        v${LITERT_VERSION}
    GIT_SHALLOW    TRUE
    GIT_PROGRESS   TRUE
)
FetchContent_GetProperties(tensorflow)
if(NOT tensorflow_POPULATED)
    FetchContent_Populate(tensorflow)
endif()

set(TFLITE_SOURCE_DIR "${tensorflow_SOURCE_DIR}/tensorflow/lite")
add_subdirectory("${TFLITE_SOURCE_DIR}/c" "${CMAKE_BINARY_DIR}/tflite_c")

# TFLite pins its targets to C++17 in its own CMake scope, which overrides the
# global CMAKE_CXX_STANDARD. MSVC then rejects TFLite's C++20 designated
# initializers (C7555); clang/gcc accept them as an extension. So on MSVC, bump
# every target the TFLite subtree produced to C++20 (target property wins).
function(_litert_force_cxx20 dir)
    get_property(_subs DIRECTORY "${dir}" PROPERTY SUBDIRECTORIES)
    foreach(_s ${_subs})
        _litert_force_cxx20("${_s}")
    endforeach()
    get_property(_tgts DIRECTORY "${dir}" PROPERTY BUILDSYSTEM_TARGETS)
    foreach(_t ${_tgts})
        get_target_property(_type ${_t} TYPE)
        if(NOT _type STREQUAL "INTERFACE_LIBRARY" AND NOT _type STREQUAL "UTILITY")
            set_property(TARGET ${_t} PROPERTY CXX_STANDARD 20)
        endif()
    endforeach()
endfunction()
if(MSVC)
    _litert_force_cxx20("${TFLITE_SOURCE_DIR}/c")
endif()

# Install. Library:
install(TARGETS tensorflowlite_c
    RUNTIME DESTINATION lib   # .dll
    LIBRARY DESTINATION lib   # .so / .dylib
    ARCHIVE DESTINATION lib)  # .a / .lib

# Headers: layout matches faressc/tflite-c-lib (which anira consumes). The c/*.h
# headers + builtin_ops.h flatten into include/tensorflow/lite/ (so
# `#include "tensorflow/lite/c_api.h"` resolves); core/* keep their subpaths.
install(FILES
        "${TFLITE_SOURCE_DIR}/c/c_api.h"
        "${TFLITE_SOURCE_DIR}/c/c_api_experimental.h"
        "${TFLITE_SOURCE_DIR}/c/c_api_types.h"
        "${TFLITE_SOURCE_DIR}/c/common.h"
        "${TFLITE_SOURCE_DIR}/builtin_ops.h"
    DESTINATION "include/tensorflow/lite")
install(DIRECTORY "${TFLITE_SOURCE_DIR}/core/c/"
    DESTINATION "include/tensorflow/lite/core/c" FILES_MATCHING PATTERN "*.h")
install(DIRECTORY "${TFLITE_SOURCE_DIR}/core/async/c/"
    DESTINATION "include/tensorflow/lite/core/async/c" FILES_MATCHING PATTERN "*.h")
