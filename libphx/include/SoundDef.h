#ifndef PHX_SoundDef
#define PHX_SoundDef

#include "Common.h"
#include "RefCounted.h"

/* miniaudio types are hidden behind pointers so that only the audio .cpp files
 * need to include the (very large) miniaudio.h header. */
struct ma_resource_manager_data_source;
struct ma_sound;
struct SoundNotify;

/* Shared, reference-counted description of a loaded audio asset. Owned data
 * source decodes the file (DECODE flag, FMOD_CREATESAMPLE equivalent) once per
 * name/flags pair; individual Sound voices are backed by the resource
 * manager's path-keyed cache of that same decoded data. */
struct SoundDesc {
  RefCounted;
  ma_resource_manager_data_source* ds;
  SoundNotify*                     notif;
  cstr        mapKey;    /* Key this desc is registered under in Audio's StrMap. */
  cstr        name;
  cstr        path;
  bool        isLooped;
  bool        is3D;
  int32       loadResult;  /* 0 = loading, 1 = success, < 0 = ma_result error */
  float       duration;
};

typedef uint8 SoundState;
const SoundState SoundState_Null     = 0;
const SoundState SoundState_Loading  = 1;
const SoundState SoundState_Paused   = 2;
const SoundState SoundState_Playing  = 3;
const SoundState SoundState_Finished = 4;
const SoundState SoundState_Freed    = 5;

struct Sound {
  SoundDesc*    desc;
  ma_sound*     handle;
  SoundState    state;
  Vec3f const*  autoPos;
  Vec3f const*  autoVel;
  bool          freeOnFinish;
};

#endif
