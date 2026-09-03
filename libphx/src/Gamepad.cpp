#include "Gamepad.h"
#include "GamepadAxis.h"
#include "GamepadButton.h"
#include "LinkedList.h"
#include "PhxMath.h"
#include "PhxMemory.h"
#include "SDL.h"
#include "TimeStamp.h"

struct Gamepad {
  LinkedListCell(gamepadList, Gamepad);
  SDL_Gamepad* handle;
  TimeStamp lastActive;
  double axisState[GamepadAxis_SIZE];
  double axisLast[GamepadAxis_SIZE];
  double deadzone[GamepadAxis_SIZE];
  bool buttonState[GamepadButton_SIZE];
  bool buttonLast[GamepadButton_SIZE];
};

static LinkedList(gamepadList, Gamepad) = 0;

static void Gamepad_UpdateState (Gamepad* self) {
  TimeStamp now = TimeStamp_Get();
  for (GamepadAxis i = GamepadAxis_BEGIN; i <= GamepadAxis_END; ++i) {
    double state = Gamepad_GetAxis(self, i);
    if (self->axisState[i] != state)
      self->lastActive = now;
    self->axisLast[i] = self->axisState[i];
    self->axisState[i] = state;
  }

  for (GamepadButton i = GamepadButton_BEGIN; i <= GamepadButton_END; ++i) {
    bool state = Gamepad_GetButton(self, i);
    if (self->buttonState[i] != state)
      self->lastActive = now;
    self->buttonLast[i] = self->buttonState[i];
    self->buttonState[i] = state;
  }
}

/* SDL3 takes joystick *instance IDs* where SDL2 took device indices.
 * The engine-internal contract is index-based (callers loop 0..GetCount-1),
 * so translate here to keep every caller unchanged. */
static SDL_JoystickID Gamepad_JoystickIDForIndex (int index) {
  int count = 0;
  SDL_JoystickID* ids = SDL_GetJoysticks(&count);
  if (!ids || index < 0 || index >= count) {
    if (ids) SDL_free(ids);
    return 0;
  }
  SDL_JoystickID id = ids[index];
  SDL_free(ids);
  return id;
}

bool Gamepad_CanOpen (int index) {
  SDL_JoystickID id = Gamepad_JoystickIDForIndex(index);
  return id != 0 && SDL_IsGamepad(id);
}

Gamepad* Gamepad_Open (int index) {
  SDL_JoystickID id = Gamepad_JoystickIDForIndex(index);
  if (id == 0)
    return 0;
  SDL_Gamepad* handle = SDL_OpenGamepad(id);
  if (!handle)
    return 0;
  Gamepad* self = MemNewZero(Gamepad);
  self->handle = handle;
  self->lastActive = TimeStamp_Get();
  LinkedList_Insert(gamepadList, self);
  Gamepad_UpdateState(self);
  return self;
}

void Gamepad_Close (Gamepad* self) {
  LinkedList_Remove(gamepadList, self);
  SDL_CloseGamepad(self->handle);
  MemFree(self);
}

int Gamepad_AddMappings (cstr file) {
  return SDL_AddGamepadMappingsFromFile(file);
}

double Gamepad_GetAxis (Gamepad* self, GamepadAxis axis) {
  double value = (double)SDL_GetGamepadAxis(
    self->handle, (SDL_GamepadAxis)axis) / 32767.0;
  double deadzone = self->deadzone[axis];
  if (value >  deadzone) return (value - deadzone) / (1.0 - deadzone);
  if (value < -deadzone) return (value + deadzone) / (1.0 - deadzone);
  return 0.0;
}

double Gamepad_GetAxisDelta (Gamepad* self, GamepadAxis axis) {
  return self->axisState[axis] - self->axisLast[axis];
}

bool Gamepad_GetButton (Gamepad* self, GamepadButton button) {
  return SDL_GetGamepadButton(self->handle, (SDL_GamepadButton)button) == 1;
}

double Gamepad_GetButtonPressed (Gamepad* self, GamepadButton button) {
  return (self->buttonState[button] && !self->buttonLast[button]) ? 1.0 : 0.0;
}

double Gamepad_GetButtonReleased (Gamepad* self, GamepadButton button) {
  return (!self->buttonState[button] && self->buttonLast[button]) ? 1.0 : 0.0;
}

double Gamepad_GetIdleTime (Gamepad* self) {
  return TimeStamp_GetElapsed(self->lastActive);
}

int Gamepad_GetID (Gamepad* self) {
  SDL_Joystick* joystick = SDL_GetGamepadJoystick(self->handle);
  if (!joystick)
    return -1;
  return SDL_GetJoystickID(joystick);
}

cstr Gamepad_GetName (Gamepad* self) {
  return SDL_GetGamepadName(self->handle);
}

bool Gamepad_IsConnected (Gamepad* self) {
  return SDL_GamepadConnected(self->handle);
}

void Gamepad_SetDeadzone (Gamepad* self, GamepadAxis axis, double deadzone) {
  self->deadzone[axis] = deadzone;
}

void Gamepad_Update () {
  LinkedList_ForEach(gamepadList, Gamepad, self)
    Gamepad_UpdateState(self);
}
