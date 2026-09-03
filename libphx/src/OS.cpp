#include "OS.h"
#include "SDL.h"

#include <string>

cstr OS_GetClipboard () {
  /* SDL_GetClipboardText returns SDL-malloc'd memory the caller must free.
   * Cache it in a static string so callers keep the old borrow semantics
   * (no ownership transfer, no per-call leak). Single-threaded use only,
   * matching the rest of the engine's static-buffer helpers. */
  char* text = SDL_GetClipboardText();
  static std::string cache;
  cache = text ? text : "";
  SDL_free(text);
  return cache.c_str();
}

int OS_GetCPUCount () {
  return SDL_GetNumLogicalCPUCores();
}

cstr OS_GetVideoDriver () {
  return SDL_GetCurrentVideoDriver();
}

void OS_SetClipboard (cstr text) {
  if (!SDL_SetClipboardText(text))
    Fatal("OS_SetClipboard: %s", SDL_GetError());
}
