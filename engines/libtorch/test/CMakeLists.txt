cmake_minimum_required(VERSION 3.18)
project(libtorch_smoke LANGUAGES CXX)

# Consumes the PACKAGED libtorch exactly like anira does: CMAKE_PREFIX_PATH points at the
# staging tree (passed by the .github/actions/smoke verb) and find_package(Torch). This proves
# share/cmake/Torch/ survived (re)packaging and the libs link + load.
find_package(Torch REQUIRED)

# GPU variant expectation, passed by the smoke action from the preset name ("gpu" for
# *-gpu-* legs). The macOS arm64 -gpu package must prove MPS works; default packages
# must prove they are CPU-only.
set(SMOKE_VARIANT "" CACHE STRING "expected package variant: '' (cpu) | gpu")

add_executable(smoke smoke.cpp)
if(SMOKE_VARIANT STREQUAL "gpu" AND APPLE)
  target_compile_definitions(smoke PRIVATE SMOKE_EXPECT_MPS)
endif()
target_link_libraries(smoke PRIVATE "${TORCH_LIBRARIES}")
target_compile_features(smoke PRIVATE cxx_std_17)
set_target_properties(smoke PROPERTIES
    BUILD_WITH_INSTALL_RPATH TRUE
    INSTALL_RPATH "${TORCH_INSTALL_PREFIX}/lib")

# libtorch uses a synthetic model (no arg). Run via ctest like the other engines so the
# smoke action stays engine-agnostic.
enable_testing()
add_test(NAME smoke COMMAND smoke)
