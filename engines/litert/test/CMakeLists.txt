cmake_minimum_required(VERSION 3.22)
project(litert_smoke LANGUAGES CXX)

# Consumes the PACKAGED LiteRT-native archive as anira would: CMAKE_PREFIX_PATH points at the
# staging tree; we find the litert/c headers + libLiteRt and link smoke.cpp. Link proves the
# shared lib is symbol-complete; ctest runs the env create/destroy. Driven by .github/actions/smoke.

set(SMOKE_KIND "shared" CACHE STRING "shared (static deferred)")

find_path(LITERT_INC NAMES litert/c/litert_environment.h REQUIRED)
find_library(LITERT_LIB NAMES LiteRt REQUIRED)          # libLiteRt.{so,dylib} / LiteRt import-.lib
get_filename_component(LITERT_LIBDIR "${LITERT_LIB}" DIRECTORY)

add_executable(smoke smoke.cpp)
target_include_directories(smoke PRIVATE "${LITERT_INC}")
target_link_libraries(smoke PRIVATE "${LITERT_LIB}")
target_compile_features(smoke PRIVATE cxx_std_17)

if(MSVC)
  set_property(TARGET smoke PROPERTY MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>DLL")
endif()

# Shared lib loads from the staging lib dir at runtime (rpath on unix; Windows copies the DLL).
set_target_properties(smoke PROPERTIES BUILD_WITH_INSTALL_RPATH TRUE INSTALL_RPATH "${LITERT_LIBDIR}")

enable_testing()
add_test(NAME smoke COMMAND smoke)
