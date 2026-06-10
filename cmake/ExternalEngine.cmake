# Orchestrate an engine whose own build system does the heavy lifting (onnxruntime,
# libtorch). Translate the preset's BACKENDS_* cache vars into a single call to the
# engine's stage.sh (build-from-source or repackage-prebuilt), which populates a
# staging tree; `cmake --install` then copies that tree to the install prefix.

foreach(_v BACKENDS_PLATFORM BACKENDS_ARCH BACKENDS_CONFIG BACKENDS_KIND BACKENDS_SOURCE)
  if(NOT DEFINED ${_v})
    message(FATAL_ERROR "${_v} not set — use a preset such as `cmake --preset onnx-linux-x86_64-static`")
  endif()
endforeach()

# Set at configure time for prebuilt (repackage) legs: -DBACKENDS_URL=<download url>.
set(BACKENDS_URL  "" CACHE STRING "Prebuilt download URL (when BACKENDS_SOURCE=prebuilt)")
set(BACKENDS_ABIS "" CACHE STRING "Android ABIs for a prebuilt multi-ABI AAR (onnx)")

set(_stage  "${CMAKE_BINARY_DIR}/stage")
set(_script "${CMAKE_SOURCE_DIR}/engines/${BACKENDS_ENGINE}/stage.sh")

if(BACKENDS_ENGINE STREQUAL "onnxruntime")
  set(_args ${BACKENDS_PLATFORM} ${BACKENDS_ARCH} ${BACKENDS_CONFIG}
            ${BACKENDS_KIND} ${BACKENDS_SOURCE} "${_stage}" "${BACKENDS_URL}" "${BACKENDS_ABIS}")
else() # libtorch
  set(_args ${BACKENDS_PLATFORM} ${BACKENDS_ARCH} ${BACKENDS_CONFIG}
            ${BACKENDS_KIND} ${BACKENDS_SOURCE} "${_stage}" "${BACKENDS_URL}")
endif()

add_custom_target(stage ALL
  COMMAND ${CMAKE_COMMAND} -E make_directory "${_stage}"
  COMMAND bash "${_script}" ${_args}
  WORKING_DIRECTORY "${CMAKE_SOURCE_DIR}"
  VERBATIM
  COMMENT "Staging ${BACKENDS_ENGINE} ${BACKENDS_PLATFORM}/${BACKENDS_ARCH} ${BACKENDS_KIND}/${BACKENDS_SOURCE}")

# Copy whatever stage.sh produced (litert/onnx: include/ lib/; libtorch: + share/ [bin/])
# to the install prefix. Populated at build time, copied at `cmake --install` time.
install(DIRECTORY "${_stage}/" DESTINATION ".")
