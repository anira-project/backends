cmake_minimum_required(VERSION 3.24)
project(executorch_smoke LANGUAGES CXX)

# Consumes the PACKAGED ExecuTorch exactly like anira will: CMAKE_PREFIX_PATH points at the
# staging tree (passed by the .github/actions/smoke verb) and find_package(executorch CONFIG)
# resolves lib/cmake/ExecuTorch/executorch-config.cmake. This proves the CMake package
# survived staging and every static archive links (the config carries -force_load so op /
# backend registration survives static linking).
find_package(executorch CONFIG REQUIRED)

add_executable(smoke smoke.cpp)
target_link_libraries(smoke PRIVATE ${EXECUTORCH_LIBRARIES})
target_include_directories(smoke PRIVATE ${EXECUTORCH_INCLUDE_DIRS})
target_compile_features(smoke PRIVATE cxx_std_17)

# Try to export a real add.pte with the pinned ExecuTorch wheel. If the wheel/torch aren't
# importable on this runner (e.g. a platform with no ExecuTorch pip wheel), fall back to the
# link + runtime-init smoke — the model-load path then isn't exercised, but the package is
# still proven complete + consumable. Mirrors the repo's link-only gates (WASM/Android).
find_package(Python3 COMPONENTS Interpreter)
set(_pte "${CMAKE_CURRENT_BINARY_DIR}/add.pte")
if(Python3_FOUND)
  execute_process(
    COMMAND "${Python3_EXECUTABLE}" "${CMAKE_CURRENT_SOURCE_DIR}/export_add.py" "${_pte}"
    RESULT_VARIABLE _export_rc
    OUTPUT_VARIABLE _export_out
    ERROR_VARIABLE  _export_err)
  if(_export_rc EQUAL 0 AND EXISTS "${_pte}")
    target_compile_definitions(smoke PRIVATE SMOKE_PTE="${_pte}")
    message(STATUS "executorch smoke: exported add.pte -> real model load+run smoke")
  else()
    message(STATUS "executorch smoke: add.pte export unavailable -> link + runtime-init smoke")
    message(STATUS "  (export_add.py said: ${_export_err})")
  endif()
else()
  message(STATUS "executorch smoke: no Python3 -> link + runtime-init smoke")
endif()

# Run via ctest like the other engines so the shared smoke action stays engine-agnostic.
enable_testing()
add_test(NAME smoke COMMAND smoke)
