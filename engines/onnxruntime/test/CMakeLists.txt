cmake_minimum_required(VERSION 3.22)
project(onnx_smoke LANGUAGES CXX)

# Consumes the PACKAGED onnxruntime archive exactly as anira does: CMAKE_PREFIX_PATH points at
# the staging tree (passed by the smoke action); we find the headers + the bundled lib and link
# smoke.cpp against it. Linking proves the static archive is symbol-complete; ctest runs a real
# forward pass (add.onnx: y = x + x, {1,2,3} -> {2,4,6}). Driven by .github/actions/smoke.

set(SMOKE_KIND "static" CACHE STRING "static | shared")

find_path(ORT_INC NAMES onnxruntime_cxx_api.h REQUIRED)
find_library(ORT_LIB NAMES onnxruntime REQUIRED)   # static .a/.lib, or shared .dylib/.so/import-.lib
get_filename_component(ORT_LIBDIR "${ORT_LIB}" DIRECTORY)

add_executable(smoke smoke.cpp)
target_include_directories(smoke PRIVATE "${ORT_INC}")
target_link_libraries(smoke PRIVATE "${ORT_LIB}")
target_compile_features(smoke PRIVATE cxx_std_17)

if(SMOKE_KIND STREQUAL "static")
  find_package(Threads REQUIRED)
  target_link_libraries(smoke PRIVATE Threads::Threads)
  if(WIN32)
    target_link_libraries(smoke PRIVATE advapi32)            # cpuinfo's RegGetValueW
  elseif(APPLE)
    target_link_libraries(smoke PRIVATE "-framework Foundation" "-framework CoreFoundation")
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
