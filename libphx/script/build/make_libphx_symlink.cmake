# Create bin/libphx${ARCH}.so -> <actual phx library file> so the Lua FFI
# loader (libphx/script/ffi/libphx.lua) can dlopen the engine without a
# build-type suffix. No-op when the names already match.
#
# Variables (passed via -D):
#   LINK_DIR  - directory to place the symlink in (project bin/)
#   LINK_NAME - name the loader expects (e.g. libphx64.so)
#   REAL_NAME - actual target output file name (e.g. libphx64r.so)

if (REAL_NAME STREQUAL LINK_NAME)
  return ()
endif ()

file (REMOVE "${LINK_DIR}/${LINK_NAME}")
# CREATE_LINK <original> <link> SYMBOLIC: original = what it points to, link = new name.
# Symbolic (not hard) so the link stays valid even if the linker replaces the .so inode.
file (CREATE_LINK "${REAL_NAME}" "${LINK_DIR}/${LINK_NAME}" SYMBOLIC)
message (STATUS "Created symlink ${LINK_DIR}/${LINK_NAME} -> ${REAL_NAME}")
