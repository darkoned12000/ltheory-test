cmake_minimum_required (VERSION 3.16)
project (LTheory)
set (CMAKE_BUILD_TYPE Release)
include (libphx/script/build/Shared.cmake)
add_subdirectory(libphx)
# removed test executable from root CMakeLists; add subdirectory after libphx
#add_subdirectory(test)
# nothing – test target is built in its own folder, no need to set properties here

add_executable (lt "src/Main.cpp")
phx_configure_output_dir (lt)
phx_configure_target_properties (lt)

target_compile_definitions (lt PRIVATE DEBUG=0)
target_link_libraries (lt phx)

set_target_properties (lt PROPERTIES
  OUTPUT_NAME_DEBUG "lt${ARCH}d"
  OUTPUT_NAME_RELEASE "lt${ARCH}r"
  OUTPUT_NAME_RELWITHDEBINFO "lt${ARCH}"
  OUTPUT_NAME_MINSIZEREL "lt${ARCH}rm"
  BUILD_RPATH_USE_ORIGIN TRUE
  BUILD_RPATH "$ORIGIN;$ORIGIN/../libphx/ext/lib/${PLATARCH}"
  INSTALL_RPATH_USE_ORIGIN TRUE
  INSTALL_RPATH "$ORIGIN;$ORIGIN/../libphx/ext/lib/${PLATARCH}")
