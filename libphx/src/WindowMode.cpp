#include "SDL.h"
#include "WindowMode.h"

const WindowMode WindowMode_AlwaysOnTop = (WindowMode)SDL_WINDOW_ALWAYS_ON_TOP;
const WindowMode WindowMode_Borderless  = (WindowMode)SDL_WINDOW_BORDERLESS;
const WindowMode WindowMode_Fullscreen  = (WindowMode)SDL_WINDOW_FULLSCREEN;
const WindowMode WindowMode_Hidden      = (WindowMode)SDL_WINDOW_HIDDEN;
const WindowMode WindowMode_Maximized   = (WindowMode)SDL_WINDOW_MAXIMIZED;
const WindowMode WindowMode_Minimized   = (WindowMode)SDL_WINDOW_MINIMIZED;
const WindowMode WindowMode_Resizable   = (WindowMode)SDL_WINDOW_RESIZABLE;
const WindowMode WindowMode_Shown       = 0;
