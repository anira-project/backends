cmake_minimum_required(VERSION 3.15)
project(executorch_smoke LANGUAGES CXX)

# Consumes the PACKAGED ExecuTorch exactly like anira will: the staged tree is a flat
# include/ + lib/libexecutorch.a (executorch.lib on Windows) — ONE merged archive with the
# kernel/backend registrations pre-linked into a single member (engines/executorch/
# merge-static.sh), linked ON-DEMAND with no force-load. CMAKE_PREFIX_PATH points at the
# staging tree (passed by the .github/actions/smoke verb). Running a real model here proves
# the registrations survived the merge: a dropped registration fails at execute (the
# archive still links — nothing references a dropped static initializer), never at link time.
if(NOT CMAKE_PREFIX_PATH)
  message(FATAL_ERROR "set CMAKE_PREFIX_PATH to the staged executorch tree (include/ lib/)")
endif()
list(GET CMAKE_PREFIX_PATH 0 _et_root)
if(WIN32)
  set(_et_lib "${_et_root}/lib/executorch.lib")
else()
  set(_et_lib "${_et_root}/lib/libexecutorch.a")
endif()
if(NOT EXISTS "${_et_lib}")
  message(FATAL_ERROR "merged ExecuTorch archive not found: ${_et_lib}")
endif()

# Variant guard (the shared smoke action derives it from the preset name): a -gpu package
# must actually REGISTER its delegates and the default package must NOT — the smoke asks the
# runtime's backend registry (get_backend_class) after runtime_init, which is the only honest
# check now that the delegates live inside the one merged archive (there is no per-delegate
# target to look for). Names as registered by ExecuTorch 1.3.1's register_backend() calls.
set(SMOKE_VARIANT "" CACHE STRING "expected package variant: '' (cpu) | gpu")
if(SMOKE_VARIANT STREQUAL "gpu")
  if(APPLE)
    set(_gpu_backends "CoreMLBackend,MPSBackend")
    if(CMAKE_OSX_ARCHITECTURES MATCHES "arm64" AND NOT IOS)   # the smoke action sets it per leg (x86_64 legs cross-build on arm64 runners)
      string(APPEND _gpu_backends ",MLXBackend")   # macOS arm64 -gpu only (no Intel-mac MLX)
    endif()
  else()
    set(_gpu_backends "VulkanBackend")
  endif()
elseif(NOT SMOKE_VARIANT STREQUAL "")
  message(FATAL_ERROR "unknown SMOKE_VARIANT '${SMOKE_VARIANT}'")
endif()

add_executable(smoke smoke.cpp)
if(SMOKE_VARIANT STREQUAL "gpu")
  target_compile_definitions(smoke PRIVATE SMOKE_GPU_BACKENDS="${_gpu_backends}")
endif()
target_include_directories(smoke SYSTEM PRIVATE
  "${_et_root}/include"
  # The ExecuTorch headers include their vendored c10 as <c10/...>.
  "${_et_root}/include/executorch/runtime/core/portable_type/c10")
# The compile interface the exported targets used to carry (see the anira CMake, which
# mirrors this): vendored c10 must not look for a generated cmake_macros.h; logging is
# compiled out of the runtime; the threadpool extension is built in.
target_compile_definitions(smoke PRIVATE C10_USING_CUSTOM_GENERATED_MACROS ET_LOG_ENABLED=0 ET_USE_THREADPOOL)
target_compile_features(smoke PRIVATE cxx_std_17)

find_package(Threads REQUIRED)
if(WIN32)
  # No partial link on COFF: the registration set ships as a second, small lib that the
  # consumer whole-archives next to the on-demand one (anira does the same on Windows).
  target_link_libraries(smoke PRIVATE "${_et_lib}" Threads::Threads)
  target_link_options(smoke PRIVATE "/WHOLEARCHIVE:${_et_root}/lib/executorch_registrations.lib")
else()
  target_link_libraries(smoke PRIVATE "${_et_lib}" Threads::Threads ${CMAKE_DL_LIBS})
  if(NOT APPLE)
    target_link_libraries(smoke PRIVATE m)
  endif()
  # -gpu on Apple: the delegates' registration TUs are pre-linked into the archive, so the
  # frameworks they call must be on every consumer's link line (anira does the same):
  # CoreML delegate -> CoreML, Accelerate, Foundation, sqlite3; MPS -> Metal, MPS, MPSGraph;
  # MLX (macOS arm64) -> Metal, Foundation, Accelerate. Vulkan on Linux dlopens the loader
  # via volk, so the Linux -gpu package needs nothing beyond CMAKE_DL_LIBS.
  if(SMOKE_VARIANT STREQUAL "gpu" AND APPLE)
    target_link_libraries(smoke PRIVATE
      "-framework CoreML" "-framework Accelerate" "-framework Foundation" sqlite3
      "-framework Metal" "-framework MetalPerformanceShaders" "-framework MetalPerformanceShadersGraph")
  endif()
endif()

# A real add.pte (a+b -> {3,5,7}) is committed next to this file, exported once with the
# pinned ExecuTorch wheel (export_add.py — see its header). Using it makes EVERY leg do a
# real model load+run with no ExecuTorch/torch wheel needed at CI time, and no fragile
# fallback. Must be regenerated if VERSION changes (the .pte format is tied to the runtime
# version). If it's somehow absent, try exporting on the fly; else a link + runtime-init smoke.
set(_pte "")
if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/add.pte")
  configure_file("${CMAKE_CURRENT_SOURCE_DIR}/add.pte" "${CMAKE_CURRENT_BINARY_DIR}/add.pte" COPYONLY)
  set(_pte "${CMAKE_CURRENT_BINARY_DIR}/add.pte")
  message(STATUS "executorch smoke: committed add.pte -> real model load+run smoke")
else()
  find_package(Python3 COMPONENTS Interpreter)
  if(Python3_FOUND)
    execute_process(
      COMMAND "${Python3_EXECUTABLE}" "${CMAKE_CURRENT_SOURCE_DIR}/export_add.py" "${CMAKE_CURRENT_BINARY_DIR}/add.pte"
      RESULT_VARIABLE _export_rc ERROR_VARIABLE _export_err)
    if(_export_rc EQUAL 0 AND EXISTS "${CMAKE_CURRENT_BINARY_DIR}/add.pte")
      set(_pte "${CMAKE_CURRENT_BINARY_DIR}/add.pte")
      message(STATUS "executorch smoke: exported add.pte -> real model load+run smoke")
    else()
      message(STATUS "executorch smoke: add.pte unavailable -> link + runtime-init smoke (${_export_err})")
    endif()
  else()
    message(STATUS "executorch smoke: no add.pte, no Python3 -> link + runtime-init smoke")
  endif()
endif()
if(_pte)
  target_compile_definitions(smoke PRIVATE SMOKE_PTE="${_pte}")
endif()

# Run via ctest like the other engines so the shared smoke action stays engine-agnostic.
enable_testing()
add_test(NAME smoke COMMAND smoke)
