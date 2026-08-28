cmake_minimum_required (VERSION 3.16)
project (LibPHX)
set (CMAKE_BUILD_TYPE Release)
include (script/build/Shared.cmake)

# ------------------------------------------------------------------------------

file (GLOB HEADERS "include/*.h")
file (GLOB SOURCES "src/*.cpp")

add_library (phx SHARED ${SOURCES} ${HEADERS})
phx_configure_output_dir (phx)
phx_configure_target_properties (phx)

target_compile_definitions (phx PRIVATE LIBPHX_BUILDING=1)
target_include_directories (phx PUBLIC "include")
target_include_directories (phx PUBLIC "ext/include")
target_include_directories (phx SYSTEM PUBLIC "/usr/include/bullet")

set_target_properties (phx PROPERTIES
  PREFIX "lib"
  OUTPUT_NAME_DEBUG "phx${ARCH}d"
  OUTPUT_NAME_RELEASE "phx${ARCH}r"
  OUTPUT_NAME_RELWITHDEBINFO "phx${ARCH}"
  OUTPUT_NAME_MINSIZEREL "phx${ARCH}rm")

# ------------------------------------------------------------------------------

# NOTE : Windows support was removed on 2026-08-28 (ext/lib/win32|win64 and the
#        bundled FMOD SDKs were deleted). Shared.cmake still carries Windows
#        compile flags; re-add an extlib block here if a Windows port happens.

if (LINUX)

  target_link_libraries (phx
    GL
    GLEW
    dl
    m
    pthread
    SDL2
    freetype
    luajit-5.1
    lz4
    BulletCollision BulletDynamics LinearMath)

  # miniaudio (header-only, libphx/ext/include/miniaudio) dlopens its backends
  # at runtime; pthread covers the mixer + resource-manager job threads.

  # $ORIGIN-based rpath: resolve the engine .so from any working directory, so
  # the game runs without LD_LIBRARY_PATH. $ORIGIN = dir of this .so;
  # $ORIGIN/.. = project root (for bin/).
  set_target_properties (phx PROPERTIES
    BUILD_RPATH_USE_ORIGIN TRUE
    BUILD_RPATH "$ORIGIN;$ORIGIN/.."
    INSTALL_RPATH_USE_ORIGIN TRUE
    INSTALL_RPATH "$ORIGIN;$ORIGIN/..")

  # The Lua FFI loader (libphx/script/ffi/libphx.lua) dlopens "libphx${ARCH}.so"
  # in release builds, but the Release output name carries a suffix
  # (e.g. libphx64r.so). Keep a relative symlink so ffi.load works out of the box.
  add_custom_command (TARGET phx POST_BUILD
    COMMAND ${CMAKE_COMMAND}
      -D LINK_DIR=${CMAKE_SOURCE_DIR}/bin
      -D LINK_NAME=libphx${ARCH}.so
      -D REAL_NAME=$<TARGET_FILE:phx>
      -P ${CMAKE_CURRENT_LIST_DIR}/script/build/make_libphx_symlink.cmake)

endif ()
