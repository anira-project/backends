cmake_minimum_required(VERSION 3.24)
project(executorch_smoke LANGUAGES CXX)

# Consumes the PACKAGED ExecuTorch exactly like anira will: CMAKE_PREFIX_PATH points at the
# staging tree (passed by the .github/actions/smoke verb) and find_package(executorch CONFIG)
# resolves lib/cmake/ExecuTorch/executorch-config.cmake. This proves the CMake package
# survived staging and every static archive links (the config carries -force_load so op /
# backend registration survives static linking).
find_package(executorch CONFIG REQUIRED)

add_executable(smoke smoke.cpp)

# ExecuTorch ships several op-REGISTRATION libs that each register the same aten ops
# (portable_ops_lib, optimized_ops_lib, optimized_portable_ops_lib, optimized_native_cpu_ops_lib).
# Force-loading more than one double-registers operators and the registry aborts in a static
# initializer before main(). Link only the merged optimized_native_cpu_ops_lib (optimized +
# portable fallback, the lib neural_tilde uses) plus quantized_ops_lib (disjoint namespace);
# drop the redundant registration libs. This is the same curation anira must do as a consumer.
set(_et_libs ${EXECUTORCH_LIBRARIES})
list(REMOVE_ITEM _et_libs portable_ops_lib optimized_ops_lib optimized_portable_ops_lib)
# MLX delegate: libmlxdelegate.a references mlx::core from libmlx, which the config exposes as a
# (non-force-loaded) imported `mlx` target but does NOT add to EXECUTORCH_LIBRARIES. Link it
# explicitly, after the delegate, so the mlx::core symbols resolve (macOS arm64 only).
if(TARGET mlx)
  list(APPEND _et_libs mlx)
endif()

target_link_libraries(smoke PRIVATE ${_et_libs})
target_include_directories(smoke PRIVATE ${EXECUTORCH_INCLUDE_DIRS})
target_compile_features(smoke PRIVATE cxx_std_17)

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
