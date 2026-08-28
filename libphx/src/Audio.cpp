#include "ArrayList.h"
#include "Audio.h"
#include "MemPool.h"
#include "PhxMath.h"
#include "Sound.h"
#include "SoundDef.h"
#include "StrMap.h"
#include "Vec3.h"
#define MINIAUDIO_IMPLEMENTATION
#include <miniaudio/miniaudio.h>

/* NOTE : miniaudio has no fixed voice limit; this only feeds the debug warning
 *        that mirrors the old FMOD channel cap. */
#define AUDIO_CHANNELS 1024
#define SOUNDPOOL_BLOCK_SIZE 128

struct Audio {
  ma_engine*        handle;
  ma_resource_manager rm;
  StrMap*           descMap;
  MemPool*          soundPool;
  ArrayList(Sound*, playingSounds);
  ArrayList(Sound*, freeingSounds);

  Vec3f const* autoPos;
  Vec3f const* autoVel;
  Vec3f const* autoFwd;
  Vec3f const* autoUp;

  float doppler;
  float scale;    /* World units per meter (FMOD 'distance factor' equivalent). */
  float rolloff;
} static self;

void Audio_Init () {
  /* Resource manager: decode everything to f32 so the mixing path and the
   * SoundDesc_ToFile export see a uniform format. One job thread handles
   * async (Sound_LoadAsync) loads. */ {
    ma_resource_manager_config rmConfig = ma_resource_manager_config_init();
    rmConfig.decodedFormat = ma_format_f32;
    if (ma_resource_manager_init(&rmConfig, &self.rm) != MA_SUCCESS)
      Fatal("Audio_Init: Failed to initialize miniaudio resource manager");
  }

  /* Engine. Backends are probed at runtime (PulseAudio/ALSA/JACK via dlopen on
   * Linux; WASAPI on Windows; CoreAudio on macOS). The mixer is forced to
   * stereo so spatialized 3D sounds always land in FL/FR — with the native
   * channel count (e.g. a 5.1 Pulse profile) a sound dead-ahead of the camera
   * would be panned into the center channel and vanish on stereo speakers. */ {
    self.handle = (ma_engine*) MemAlloc(sizeof(ma_engine));
    ma_engine_config config = ma_engine_config_init();
    config.pResourceManager = &self.rm;
    config.channels = 2;
    /* Bigger device periods + smoothed gains: small periods underrun under
     * game load (audible crackle), and unsmoothed per-frame volume/pitch
     * changes produce zipper noise. */
    config.periodSizeInMilliseconds = 40;
    config.gainSmoothTimeInMilliseconds = 100;
    config.defaultVolumeSmoothTimeInPCMFrames = 4800; /* 100ms @ 48 kHz */
    if (ma_engine_init(&config, self.handle) != MA_SUCCESS)
      Fatal("Audio_Init: Failed to initialize miniaudio engine");
  }

  /* Initialize audio instance data. */ {
    self.descMap = StrMap_Create(128);
    self.soundPool = MemPool_Create(sizeof(Sound), SOUNDPOOL_BLOCK_SIZE);
    self.doppler = 0.0f;
    self.scale = 1.0f;
    self.rolloff = 1.0f;
  }
}

void Audio_Free () {
  /* Release any sounds that are still alive so their voices are uninit'd
   * before the engine goes away. */
  ArrayList_ForEachI(self.playingSounds, i) {
    Sound* sound = ArrayList_Get(self.playingSounds, i);
    if (!Sound_IsFreed(sound)) Sound_Free(sound);
  }
  ArrayList_ForEachI(self.freeingSounds, i) {
    Sound* sound = ArrayList_Get(self.freeingSounds, i);
    Audio_DeallocSound(sound);
  }
  ArrayList_Clear(self.freeingSounds);

  ma_engine_uninit(self.handle);
  MemFree(self.handle);
  self.handle = 0;
  ma_resource_manager_uninit(&self.rm);
  StrMap_Free(self.descMap);
  MemPool_Free(self.soundPool);
  ArrayList_Free(self.playingSounds);
  ArrayList_Free(self.freeingSounds);
}

void Audio_AttachListenerPos (Vec3f const* pos, Vec3f const* vel, Vec3f const* fwd, Vec3f const* up) {
  self.autoPos = pos;
  self.autoVel = vel;
  self.autoFwd = fwd;
  self.autoUp  = up;
  Audio_SetListenerPos(pos, vel, fwd, up);
}

void Audio_Set3DSettings (float doppler, float scale, float rolloff) {
  /* Applied per-voice at voice creation (ma_sound_set_doppler_factor etc.);
   * miniaudio has no engine-wide doppler/rolloff switch. */
  self.doppler = doppler;
  self.scale = scale;
  self.rolloff = rolloff;
}

void Audio_SetListenerPos (
  Vec3f const* pos,
  Vec3f const* vel,
  Vec3f const* fwd,
  Vec3f const* up)
{
  Assert(!fwd || Approx(Vec3f_Length(*fwd), 1));
  Assert(!up || Approx(Vec3f_Length(*up), 1));
  Assert(!fwd || !up || Approx(Vec3f_Dot(*fwd, *up), 0));

  if (pos) ma_engine_listener_set_position(self.handle, 0, pos->x, pos->y, pos->z);
  if (vel) ma_engine_listener_set_velocity(self.handle, 0, vel->x, vel->y, vel->z);
  if (fwd) ma_engine_listener_set_direction(self.handle, 0, fwd->x, fwd->y, fwd->z);
  if (up)  ma_engine_listener_set_world_up(self.handle, 0, up->x, up->y, up->z);
}

void Audio_Update () {
  Audio_SetListenerPos(self.autoPos, self.autoVel, self.autoFwd, self.autoUp);

  ArrayList_ForEachI(self.playingSounds, i) {
    Sound* sound = ArrayList_Get(self.playingSounds, i);
    /* TODO : Refine the API to make this less awkward */
    if (!Sound_IsFreed(sound) && Sound_IsPlaying(sound)) {
      Sound_Update(sound);
      /* State was polled from the mixer via channel callbacks under FMOD; with
       * miniaudio we poll at_end here, so finished sounds lag by at most one
       * Audio_Update. */
      Sound_PollFinished(sound);
    } else {
      ArrayList_RemoveAtFast(self.playingSounds, i--);
    }
  }

  ArrayList_ForEachI(self.freeingSounds, i) {
    Sound* sound = ArrayList_Get(self.freeingSounds, i);
    Audio_DeallocSound(sound);
  }
  ArrayList_Clear(self.freeingSounds);
}

int32 Audio_GetLoadedCount () {
  uint32 size = StrMap_GetSize(self.descMap);
  Assert(size <= INT32_MAX);
  return (int32) size;
}

int32 Audio_GetPlayingCount () {
  return ArrayList_GetSize (self.playingSounds);
}

int32 Audio_GetTotalCount () {
  uint32 size = MemPool_GetSize(self.soundPool);
  Assert(size <= INT32_MAX);
  return (int32) size;
}

void* Audio_GetHandle () {
  return self.handle;
}

float Audio_GetDoppler () {
  return self.doppler;
}

float Audio_GetScale () {
  return self.scale;
}

float Audio_GetRolloff () {
  return self.rolloff;
}

SoundDesc* Audio_AllocSoundDesc (cstr name) {
  SoundDesc* desc = (SoundDesc*) StrMap_Get(self.descMap, name);
  if (!desc) {
    desc = MemNewZero(SoundDesc);
    StrMap_Set(self.descMap, name, desc);
  }
  return desc;
}

void Audio_DeallocSoundDesc (SoundDesc* desc) {
  StrMap_Remove(self.descMap, desc->mapKey);
  MemFree(desc);
}

Sound* Audio_AllocSound () {
  return (Sound*) MemPool_Alloc(self.soundPool);
}

void Audio_DeallocSound (Sound* sound) {
  if (sound->handle) {
    ma_sound_uninit(sound->handle);
    MemFree(sound->handle);
    sound->handle = 0;
  }
  MemPool_Dealloc(self.soundPool, sound);
}

void Audio_SoundStateChanged (Sound* sound) {
  if (Sound_IsFreed(sound)) {
    ArrayList_Append(self.freeingSounds, sound);
  } else if (Sound_IsPlaying(sound)) {
    ArrayList_Append(self.playingSounds, sound);

    CHECK1(
      if (ArrayList_GetSize(self.playingSounds) == AUDIO_CHANNELS + 1)
        Warn("Audio: Exceeded the number of available sound channels (%i)", AUDIO_CHANNELS);
    )
  }
}
