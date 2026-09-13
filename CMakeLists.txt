cmake_minimum_required (VERSION 3.16)
project (LTheory)
set (CMAKE_BUILD_TYPE Release)

# Export compile_commands.json for clangd/IDE code intelligence
set (CMAKE_EXPORT_COMPILE_COMMANDS ON)

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

# Explicitly register libphx headers for src/Main.cpp
target_include_directories (lt PRIVATE ${CMAKE_SOURCE_DIR}/libphx/include)

target_compile_definitions (lt PRIVATE DEBUG=0)
target_link_libraries (lt phx)

# --- Build-time shader validation gate --------------------------------------
add_custom_target (phx_validate_glsl
  COMMAND "${PHX_VALIDATOR_PY}" tools/validate_glsl.py 460
  WORKING_DIRECTORY ${CMAKE_SOURCE_DIR}
  COMMENT "Validating GLSL shaders (offline compile+link)"
  VERBATIM)

add_dependencies (lt phx_validate_glsl)

# --- Build-time Bytes LZ4 validation gate -----------------------------------
add_custom_target (phx_validate_bytes
  COMMAND "${CMAKE_SOURCE_DIR}/libphx/ext/bin/linux64/luajit" tools/validate_bytes.lua
  WORKING_DIRECTORY ${CMAKE_SOURCE_DIR}
  COMMENT "Validating Bytes LZ4 round-trip (safe decompress)"
  VERBATIM)

add_dependencies (lt phx_validate_bytes)
add_dependencies (phx_validate_bytes phx)

add_custom_target (phx_validate_drawbatch
  COMMAND "${CMAKE_SOURCE_DIR}/libphx/ext/bin/linux64/luajit" tools/validate_drawbatch.lua
  WORKING_DIRECTORY ${CMAKE_SOURCE_DIR}
  COMMENT "Validating DrawBatch grouping (consecutive-run, order-preserving)"
  VERBATIM)

add_dependencies (lt phx_validate_drawbatch)
add_dependencies (phx_validate_drawbatch phx)

add_custom_target (phx_validate_immdraw
  COMMAND "${CMAKE_SOURCE_DIR}/libphx/ext/bin/linux64/luajit" tools/validate_immdraw.lua
  WORKING_DIRECTORY ${CMAKE_SOURCE_DIR}
  COMMENT "Validating immediate-draw batch run signature (ImmBatch_KeyMatch)"
  VERBATIM)

add_dependencies (lt phx_validate_immdraw)
add_dependencies (phx_validate_immdraw phx)

add_custom_target (phx_validate_renderqueue
  COMMAND "${CMAKE_SOURCE_DIR}/libphx/ext/bin/linux64/luajit" tools/validate_renderqueue.lua
  WORKING_DIRECTORY ${CMAKE_SOURCE_DIR}
  COMMENT "Validating RenderJobQueue threading (barrier, order, shutdown)"
  VERBATIM)

add_dependencies (lt phx_validate_renderqueue)
add_dependencies (phx_validate_renderqueue phx)

# --- Build-time SDL validation gates ---------------------------------------
add_custom_target (phx_validate_sdl
  COMMAND "${PHX_VALIDATOR_PY}" tools/validate_sdl.py
  WORKING_DIRECTORY ${CMAKE_SOURCE_DIR}
  COMMENT "Validating SDL pkg/header/init (dummy video)"
  VERBATIM)

add_custom_target (phx_validate_sdl_window
  COMMAND "${PHX_VALIDATOR_PY}" tools/validate_sdl_window.py
  WORKING_DIRECTORY ${CMAKE_SOURCE_DIR}
  COMMENT "Validating SDL hidden window + GL context"
  VERBATIM)

add_custom_target (phx_validate_sdl_input
  COMMAND "${PHX_VALIDATOR_PY}" tools/validate_sdl_input.py
  WORKING_DIRECTORY ${CMAKE_SOURCE_DIR}
  COMMENT "Validating SDL GameController/Gamepad wiring"
  VERBATIM)

add_dependencies (lt phx_validate_sdl phx_validate_sdl_window phx_validate_sdl_input)

# --- Build-time HUD reticle parity gate ------------------------------------
add_custom_target (phx_validate_hud
  COMMAND "${CMAKE_SOURCE_DIR}/libphx/ext/bin/linux64/luajit" tools/validate_hud_reticle.lua
  WORKING_DIRECTORY ${CMAKE_SOURCE_DIR}
  COMMENT "Validating HUD reticle/turret parity (mouse vs gamepad)"
  VERBATIM)

add_dependencies (lt phx_validate_hud)

set_target_properties (lt PROPERTIES
  OUTPUT_NAME_DEBUG "lt${ARCH}d"
  OUTPUT_NAME_RELEASE "lt${ARCH}r"
  OUTPUT_NAME_RELWITHDEBINFO "lt${ARCH}"
  OUTPUT_NAME_MINSIZEREL "lt${ARCH}rm"
  BUILD_RPATH_USE_ORIGIN TRUE
  BUILD_RPATH "$ORIGIN;$ORIGIN/.."
  INSTALL_RPATH_USE_ORIGIN TRUE
  INSTALL_RPATH "$ORIGIN;$ORIGIN/..")
