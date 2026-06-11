cmake_minimum_required(VERSION 3.22)
project(tflite_smoke LANGUAGES CXX)

# Consumes the PACKAGED tflite archive exactly as anira does: CMAKE_PREFIX_PATH points at the
# staging tree (passed by the smoke action); we find the headers + the bundled lib and link
# smoke.cpp against it. Linking proves the archive is symbol-complete; ctest runs a real
# forward pass (add.bin: {1,3} -> {3,9}). Driven by the .github/actions/smoke verb.

set(SMOKE_KIND "static" CACHE STRING "static | shared")

find_path(TFLITE_INC NAMES tensorflow/lite/c_api.h REQUIRED)
find_library(TFLITE_LIB NAMES tensorflowlite_c REQUIRED)   # static .a/.lib, or shared .dylib/.so/import-.lib
get_filename_component(TFLITE_LIBDIR "${TFLITE_LIB}" DIRECTORY)

add_executable(smoke smoke.cpp)
target_include_directories(smoke PRIVATE "${TFLITE_INC}")
target_link_libraries(smoke PRIVATE "${TFLITE_LIB}")
target_compile_features(smoke PRIVATE cxx_std_17)

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
