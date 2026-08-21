#include "Common.h"
#include "Tex2D.h"

#pragma warning(push)
#pragma warning(disable:4242)
#pragma warning(disable:4244)
// stb_image is vendored third-party code. MSVC trips C4242/C4244 on its signed/unsigned
// conversions; GCC/Clang need no suppression (stb v2.30 compiles clean).
#define STB_IMAGE_IMPLEMENTATION
#include "stb/stb_image.h"
#pragma warning(pop)

uchar* Tex2D_LoadRaw (cstr path, int* sx, int* sy, int* components) {
  uchar* data = stbi_load(path, sx, sy, components, 0);
  if (!data)
    Warn("Failed to load image from '%s'", path);
  return data;
}
