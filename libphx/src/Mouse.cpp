#include "Mouse.h"
#include "SDL.h"
#include "Vec2.h"

int lastX;
int lastY;
uint32 lastState;

static uint64 lastAction;
static int scrollAmount;

void Mouse_Init () {
  float x, y;
  lastState = SDL_GetMouseState(&x, &y);
  lastX = (int) x;
  lastY = (int) y;
  lastAction = SDL_GetPerformanceCounter();
  scrollAmount = 0;
}

void Mouse_Free () {
}

void Mouse_SetScroll (int amount) {
  scrollAmount = amount;
}

void Mouse_Update () {
  int lx = lastX, ly = lastY;
  uint32 state = lastState;
  float x, y;
  lastState = SDL_GetMouseState(&x, &y);
  lastX = (int) x;
  lastY = (int) y;
  if (lx != lastX || ly != lastY || state != lastState)
    lastAction = SDL_GetPerformanceCounter();
  scrollAmount = 0;
}

void Mouse_GetDelta (Vec2i* out) {
  float x, y;
  SDL_GetMouseState(&x, &y);
  out->x = (int) x - lastX;
  out->y = (int) y - lastY;
}

double Mouse_GetIdleTime () {
  uint64 now = SDL_GetPerformanceCounter();
  return (double)(now - lastAction) / (double)SDL_GetPerformanceFrequency();
}

void Mouse_GetPosition (Vec2i* out) {
  float x, y;
  SDL_GetMouseState(&x, &y);
  out->x = (int) x;
  out->y = (int) y;
}

void Mouse_GetPositionGlobal (Vec2i* out) {
  float x, y;
  SDL_GetGlobalMouseState(&x, &y);
  out->x = (int) x;
  out->y = (int) y;
}

int Mouse_GetScroll () {
  return scrollAmount;
}

void Mouse_SetPosition (int x, int y) {
  SDL_WarpMouseInWindow(0, (float) x, (float) y);
}

void Mouse_SetVisible (bool visible) {
  if (visible)
    SDL_ShowCursor();
  else
    SDL_HideCursor();
}

bool Mouse_Down (MouseButton button) {
  button = SDL_BUTTON_MASK(button);
  return (SDL_GetMouseState(NULL, NULL) & button) > 0;
}

bool Mouse_Pressed (MouseButton button) {
  button = SDL_BUTTON_MASK(button);
  uint32 current = SDL_GetMouseState(NULL, NULL);
  return (current & button) && !(lastState & button);
}

bool Mouse_Released (MouseButton button) {
  button = SDL_BUTTON_MASK(button);
  uint32 current = SDL_GetMouseState(NULL, NULL);
  return !(current & button) && (lastState & button);
}
