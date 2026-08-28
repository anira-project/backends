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

add_executable(smoke smoke.cpp)
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
