cmake_minimum_required(VERSION 3.18)
project(libtorch_smoke LANGUAGES CXX)

# Consumes the PACKAGED libtorch exactly like anira does: point CMAKE_PREFIX_PATH at
# the staging tree (passed in by smoke-torch.sh) and find_package(Torch). This proves
# share/cmake/Torch/ survived (re)packaging and the libs link + load.
find_package(Torch REQUIRED)

add_executable(smoke smoke.cpp)
target_link_libraries(smoke PRIVATE "${TORCH_LIBRARIES}")
target_compile_features(smoke PRIVATE cxx_std_17)
set_target_properties(smoke PROPERTIES
    BUILD_WITH_INSTALL_RPATH TRUE
    INSTALL_RPATH "${TORCH_INSTALL_PREFIX}/lib")
