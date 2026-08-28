cmake_minimum_required (VERSION 3.16)
project (LTheory)
set (CMAKE_BUILD_TYPE Release)
include (libphx/script/build/Shared.cmake)
add_subdirectory(libphx)

# The offline shader validator needs moderngl, which lives under the 3.13
# interpreter on this host; pin it unless PHX_VALIDATOR_PY points elsewhere.
find_package (Python3 COMPONENTS Interpreter QUIET)
if (NOT Python3_EXECUTABLE AND NOT PHX_VALIDATOR_PY)
  execute_process (COMMAND bash "-c" "command -v python3.13 || echo /usr/bin/python3" OUTPUT_VARIABLE _py OUTPUT_STRIP_TRAILING_WHITESPACE)
  set (PHX_VALIDATOR_PY "${_py}" CACHE STRING "" FORCE)
endif ()

add_executable (lt "src/Main.cpp")
phx_configure_output_dir (lt)
phx_configure_target_properties (lt)

target_compile_definitions (lt PRIVATE DEBUG=0)
target_link_libraries (lt phx)

# --- Build-time shader validation gate --------------------------------------
# The offline validator compiles+links every shader headlessly (moderngl/EGL).
# Runs after `lt` is built so a broken .glsl fails the build now instead of
# aborting at first draw at runtime. Failures make `cmake --build` return non-zero.
add_custom_target (phx_validate_glsl
  COMMAND "${PHX_VALIDATOR_PY}" tools/validate_glsl.py 460
  WORKING_DIRECTORY ${CMAKE_SOURCE_DIR}
  COMMENT "Validating GLSL shaders (offline compile+link)"
  VERBATIM)

add_dependencies (lt phx_validate_glsl)

# --- Build-time Bytes LZ4 validation gate -----------------------------------
# Offline round-trip for Bytes_Compress/Decompress (libphx/src/Bytes.cpp).
# Uses the vendored/bundled LuaJIT (libphx/ext/bin/linux64/luajit, now OpenResty
# rolling) so it works without a system luajit. Fails the build if the
# safe-decompress (LZ4_decompress_safe + compressBound) framing regresses.
add_custom_target (phx_validate_bytes
  COMMAND "${CMAKE_SOURCE_DIR}/libphx/ext/bin/linux64/luajit" tools/validate_bytes.lua
  WORKING_DIRECTORY ${CMAKE_SOURCE_DIR}
  COMMENT "Validating Bytes LZ4 round-trip (safe decompress)"
  VERBATIM)

add_dependencies (lt phx_validate_bytes)

set_target_properties (lt PROPERTIES
  OUTPUT_NAME_DEBUG "lt${ARCH}d"
  OUTPUT_NAME_RELEASE "lt${ARCH}r"
  OUTPUT_NAME_RELWITHDEBINFO "lt${ARCH}"
  OUTPUT_NAME_MINSIZEREL "lt${ARCH}rm"
  BUILD_RPATH_USE_ORIGIN TRUE
  BUILD_RPATH "$ORIGIN;$ORIGIN/.."
  INSTALL_RPATH_USE_ORIGIN TRUE
  INSTALL_RPATH "$ORIGIN;$ORIGIN/..")
