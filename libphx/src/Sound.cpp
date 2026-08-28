#include "Audio.h"
#include "PhxMemory.h"
#include "PhxMath.h"
#include "Sound.h"
#include "SoundDesc.h"
#include "SoundDef.h"
#include "Vec3.h"
#include <miniaudio/miniaudio.h>

static void Sound_SetState(Sound*, SoundState);

inline static void Sound_EnsureLoadedImpl (Sound* self, cstr func) {
  if (self->state == SoundState_Loading) {
    SoundDesc_FinishLoad(self->desc, func);

    self->handle = (ma_sound*) MemAlloc(sizeof(ma_sound));
    ma_result result = ma_sound_init_from_file(
      (ma_engine*) Audio_GetHandle(),
      self->desc->path,
      MA_SOUND_FLAG_DECODE,
      0, 0, self->handle);
    if (result != MA_SUCCESS)
      Fatal("%s: Failed to create sound voice.\n  Path: %s", func, self->desc->path);

    /* NOTE : Looping/spatialization are per-voice in miniaudio (FMOD put them
     *        in the sound's mode bits). The resource manager dedupes the
     *        decoded data by path, so clones share decoded memory but each
     *        voice keeps its own cursor. */
    ma_sound_set_looping(self->handle, self->desc->isLooped);
    ma_sound_set_spatialization_enabled(self->handle, self->desc->is3D);
    ma_sound_set_doppler_factor(self->handle, Audio_GetDoppler());
    ma_sound_set_min_distance(self->handle, Audio_GetScale());
    ma_sound_set_rolloff(self->handle, Audio_GetRolloff());
    Sound_SetState(self, SoundState_Paused);

    if (Sound_Get3D(self)) {
      Vec3f zero = { 0, 0, 0 };
      Sound_Set3DPos(self, &zero, &zero);
    }
  }
}
#define Sound_EnsureLoaded(...) Sound_EnsureLoadedImpl(__VA_ARGS__, __func__)

inline static void Sound_EnsureNotFreedImpl (Sound* self, cstr func) {
  if (self->state == SoundState_Freed) {
    cstr name = (self->desc->_refCount > 0) ? self->desc->name : "<SoundDesc has been freed>";
    Fatal("%s: Sound has been freed.\n  Name: %s", func, name);
  }
}
#define Sound_EnsureNotFreed(...) Sound_EnsureNotFreedImpl(__VA_ARGS__, __func__)

inline static void Sound_EnsureStateImpl (Sound* self, cstr func) {
  Sound_EnsureLoadedImpl(self, func);
  Sound_EnsureNotFreedImpl(self, func);
}
#define Sound_EnsureState(...) Sound_EnsureStateImpl(__VA_ARGS__, __func__)

static void Sound_SetState (Sound* self, SoundState nextState) {
  if (nextState == self->state) return;

  switch (nextState) {
    default: Fatal("Sound_SetState: Unhandled case: %i", nextState);

    case SoundState_Loading:
      Assert(self->state == SoundState_Null);
      break;

    case SoundState_Playing:
      ma_sound_start(self->handle);
      break;

    case SoundState_Paused:
      ma_sound_stop(self->handle);
      break;

    case SoundState_Finished:
      /* Reached naturally when the mixer hits the end (polled in Audio_Update)
       * or forced by Sound_Free. */
      ma_sound_stop(self->handle);
      break;

    case SoundState_Freed:
      /* NOTE : Deallocation is deferred to Audio_Update for performance. */
      break;
  }

  self->state = nextState;
  Audio_SoundStateChanged(self);

  if (self->freeOnFinish && self->state == SoundState_Finished)
    Sound_Free(self);
}

static Sound* Sound_Create (cstr name, bool immediate, bool isLooped, bool is3D) {
  SoundDesc* desc = SoundDesc_Load(name, immediate, isLooped, is3D);
  Sound* self = Audio_AllocSound();
  self->desc = desc;
  Sound_SetState(self, SoundState_Loading);
  return self;
}

Sound* Sound_Load (cstr name, bool isLooped, bool is3D) {
  Sound* self = Sound_Create(name, true, isLooped, is3D);
  Sound_EnsureLoaded(self);
  return self;
}

Sound* Sound_LoadAsync (cstr name, bool isLooped, bool is3D) {
  Sound* self = Sound_Create(name, false, isLooped, is3D);
  return self;
}

Sound* Sound_Clone (Sound* self) {
  Sound_EnsureState(self);
  Sound* clone = Audio_AllocSound();
  *clone = *self;
  SoundDesc_Acquire(self->desc);
  clone->handle = 0;
  clone->state = SoundState_Null;
  Sound_SetState(clone, SoundState_Loading);
  return clone;
}

void Sound_ToFile (Sound* self, cstr name) {
  Sound_EnsureState(self);
  SoundDesc_ToFile(self->desc, name);
}

void Sound_Acquire (Sound* self) {
  Sound_EnsureState(self);
  RefCounted_Acquire(self->desc);
}

void Sound_Free (Sound* self) {
  Sound_EnsureState(self);
  Sound_SetState(self, SoundState_Finished);
  Sound_SetState(self, SoundState_Freed);
  SoundDesc_Free(self->desc);
}

void Sound_Play (Sound* self) {
  Sound_EnsureState(self);
  Sound_SetState(self, SoundState_Playing);
}

void Sound_Pause (Sound* self) {
  Sound_EnsureState(self);
  Sound_SetState(self, SoundState_Paused);
}

void Sound_Rewind (Sound* self) {
  Sound_EnsureState(self);
  ma_sound_seek_to_pcm_frame(self->handle, 0);
}

bool Sound_Get3D (Sound* self) {
  Sound_EnsureState(self);
  return self->desc->is3D;
}

float Sound_GetDuration (Sound* self) {
  Sound_EnsureState(self);
  return SoundDesc_GetDuration(self->desc);
}

bool Sound_GetLooped (Sound* self) {
  Sound_EnsureState(self);
  return self->desc->isLooped;
}

cstr Sound_GetName (Sound* self) {
  Sound_EnsureNotFreed(self);
  return SoundDesc_GetName(self->desc);
}

cstr Sound_GetPath (Sound* self) {
  Sound_EnsureNotFreed(self);
  return SoundDesc_GetPath(self->desc);
}

bool Sound_IsFinished (Sound* self) {
  return self->state == SoundState_Finished;
}

bool Sound_IsPlaying (Sound* self) {
  return self->state == SoundState_Playing;
}

void Sound_Attach3DPos (Sound* self, Vec3f const* pos, Vec3f const* vel) {
  //EnsureState happens in Set3DPos already
  Sound_Set3DPos(self, pos, vel);
  self->autoPos = pos;
  self->autoVel = vel;
}

void Sound_Set3DLevel (Sound* self, float level) {
  Sound_EnsureState(self);
  /* Approximation of FMOD's 2D/3D level blend: any nonzero level gets full
   * spatialization; 0 disables it. */
  ma_sound_set_spatialization_enabled(self->handle, level > 0.0f);
}

void Sound_Set3DMinMaxDistance (Sound* self, float minDist, float maxDist) {
  Sound_EnsureState(self);
  ma_sound_set_min_distance(self->handle, Max(0.001f, minDist));
  if (maxDist > 0.0f)
    ma_sound_set_max_distance(self->handle, maxDist);
}

void Sound_Set3DPos (Sound* self, Vec3f const* pos, Vec3f const* vel) {
  Sound_EnsureState(self);
  Vec3f zero = { 0, 0, 0 };
  Vec3f p = pos ? *pos : zero;
  Vec3f v = vel ? *vel : zero;
  ma_sound_set_position(self->handle, p.x, p.y, p.z);
  ma_sound_set_velocity(self->handle, v.x, v.y, v.z);
}

void Sound_SetFreeOnFinish (Sound* self, bool freeOnFinish) {
  self->freeOnFinish = freeOnFinish;
}

void Sound_SetPan (Sound* self, float pan) {
  Sound_EnsureState(self);
  ma_sound_set_pan(self->handle, pan);
}

void Sound_SetPitch (Sound* self, float pitch) {
  Sound_EnsureState(self);
  ma_sound_set_pitch(self->handle, pitch);
}

void Sound_SetPlayPos (Sound* self, float seconds) {
  Sound_EnsureState(self);
  Assert(seconds >= 0.0f);
  ma_engine* engine = (ma_engine*) Audio_GetHandle();
  ma_uint64 frame = (ma_uint64) Round(seconds * (float) ma_engine_get_sample_rate(engine));
  ma_sound_seek_to_pcm_frame(self->handle, frame);
}

void Sound_SetVolume (Sound* self, float volume) {
  Sound_EnsureState(self);
  ma_sound_set_volume(self->handle, volume);
}

Sound* Sound_LoadPlay (cstr name, bool isLooped, bool is3D) {
  Sound* self = Sound_Load(name, isLooped, is3D);
  Sound_Play(self);
  return self;
}

Sound* Sound_LoadPlayAttached (cstr name, bool isLooped, bool is3D, Vec3f const* pos, Vec3f const* vel) {
  Sound* self = Sound_Load(name, isLooped, is3D);
  Sound_Attach3DPos(self, pos, vel);
  Sound_Play(self);
  return self;
}

void Sound_LoadPlayFree (cstr name, bool isLooped, bool is3D) {
  Sound* self = Sound_Load(name, isLooped, is3D);
  Sound_SetFreeOnFinish(self, true);
  Sound_Play(self);
}

void Sound_LoadPlayFreeAttached (cstr name, bool isLooped, bool is3D, Vec3f const* pos, Vec3f const* vel) {
  Sound* self = Sound_Load(name, isLooped, is3D);
  Sound_Attach3DPos(self, pos, vel);
  Sound_SetFreeOnFinish(self, true);
  Sound_Play(self);
}

Sound* Sound_ClonePlay (Sound* self) {
  Sound* clone = Sound_Clone(self);
  Sound_Play(clone);
  return clone;
}

Sound* Sound_ClonePlayAttached (Sound* self, Vec3f const* pos, Vec3f const* vel) {
  Sound* clone = Sound_Clone(self);
  Sound_Attach3DPos(clone, pos, vel);
  Sound_Play(clone);
  return clone;
}

void Sound_ClonePlayFree (Sound* self) {
  Sound* clone = Sound_Clone(self);
  Sound_SetFreeOnFinish(clone, true);
  Sound_Play(clone);
}

void Sound_ClonePlayFreeAttached (Sound* self, Vec3f const* pos, Vec3f const* vel) {
  Sound* clone = Sound_Clone(self);
  Sound_Attach3DPos(clone, pos, vel);
  Sound_SetFreeOnFinish(clone, true);
  Sound_Play(clone);
}

void Sound_Update (Sound* self) {
  if (self->state == SoundState_Loading) return;

  if (Sound_Get3D(self))
    Sound_Set3DPos(self, self->autoPos, self->autoVel);
}

bool Sound_IsFreed (Sound* self) {
  return self->state == SoundState_Freed;
}

void Sound_PollFinished (Sound* self) {
  if (self->state == SoundState_Playing && self->handle && ma_sound_at_end(self->handle))
    Sound_SetState(self, SoundState_Finished);
}

/* NOTE : We create the voice only once the (possibly async) load has finished
 *        so that per-voice settings can be applied *before* samples start
 *        getting mixed. */

/* NOTE : By default, 3D sounds are positioned at the *current position* of the
 *        listener! That's confusing and almost never what we want, so we reset
 *        the position immediately for consistency. */

/* NOTE : Finished sounds are detected by polling ma_sound_at_end in
 *        Audio_Update, so a sound could have finished earlier in the frame and
 *        we won't know until the next update. */
