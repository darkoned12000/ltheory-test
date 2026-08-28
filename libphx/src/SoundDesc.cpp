#include "Audio.h"
#include "File.h"
#include "PhxMath.h"
#include "PhxMemory.h"
#include "Resource.h"
#include "Sound.h"
#include "SoundDesc.h"
#include "SoundDef.h"
#include "PhxString.h"
#include <miniaudio/miniaudio.h>

/* Notification object fired by the resource manager's job threads when an
 * asynchronous load finishes (on success OR failure; the actual result is
 * probed afterwards). Layout-compatible with ma_async_notification: the first
 * member must be the callback pointer miniaudio invokes. */
struct SoundNotify {
  void       (*onSignal) (ma_async_notification*);
  SoundDesc* desc;
};

static void SoundNotify_OnSignal (ma_async_notification* pNotification) {
  SoundNotify* self = (SoundNotify*) pNotification;
  self->desc->loadResult = 1;
}

static void SoundDesc_CacheDuration (SoundDesc* self) {
  ma_uint64 length;
  ma_result result = ma_resource_manager_data_source_get_length_in_pcm_frames(self->ds, &length);
  if (result != MA_SUCCESS)
    Fatal("SoundDesc_CacheDuration: Failed to query length.\n  Path: %s", self->path);
  ma_engine* engine = (ma_engine*) Audio_GetHandle();
  self->duration = (float) ((double) length / ma_engine_get_sample_rate(engine));
}

void SoundDesc_FinishLoad (SoundDesc* self, cstr func) {
  if (self->loadResult != 0) return;

  /* Async load still in flight. Blocking the main thread mirrors the FMOD
   * implementation: warn once, then spin until the job thread signals. */
  bool warned = false;
  while (self->loadResult == 0) {
    if (!warned) {
      warned = true;
      Warn("%s: Background file load hasn't finished. Blocking the main thread.\n  Path: %s", func, self->path);
    }
  }

  /* The done notification fires on failure as well; probe the data source to
   * distinguish the two. */
  ma_uint64 length;
  ma_result result = ma_resource_manager_data_source_get_length_in_pcm_frames(self->ds, &length);
  if (result != MA_SUCCESS)
    Fatal("%s: Background file load has failed.\n  Path: %s", func, self->path);
  self->loadResult = 1;
  SoundDesc_CacheDuration(self);
}
#define SoundDesc_FinishLoad(...) SoundDesc_FinishLoad(__VA_ARGS__, __func__)

SoundDesc* SoundDesc_Load (cstr name, bool immediate, bool isLooped, bool is3D) {
  cstr mapKey = StrAdd(isLooped ? "LOOPED:" : "UNLOOPED:", name);
  SoundDesc* self = Audio_AllocSoundDesc(mapKey);
  if (!self->mapKey) self->mapKey = StrDup(mapKey);
  StrFree(mapKey);

  if (!self->name) {
    cstr path = Resource_GetPath(ResourceType_Sound, name);
    ma_resource_manager* rm = ma_engine_get_resource_manager((ma_engine*) Audio_GetHandle());

    ma_uint32 flags = MA_RESOURCE_MANAGER_DATA_SOURCE_FLAG_DECODE;
    if (!immediate)
      flags |= MA_RESOURCE_MANAGER_DATA_SOURCE_FLAG_ASYNC;

    self->ds = (ma_resource_manager_data_source*) MemAlloc(sizeof(ma_resource_manager_data_source));
    self->notif = (SoundNotify*) MemAlloc(sizeof(SoundNotify));
    self->notif->onSignal = SoundNotify_OnSignal;
    self->notif->desc = self;
    self->name = StrDup(name);
    self->path = StrDup(path);
    self->isLooped = isLooped;
    self->is3D = is3D;
    self->loadResult = 0;
    self->duration = 0.0f;

    if (immediate) {
      /* DECODE without ASYNC blocks inside init until fully decoded. */
      ma_result result = ma_resource_manager_data_source_init(rm, path, flags, 0, self->ds);
      if (result != MA_SUCCESS)
        Fatal("SoundDesc_Load: Failed to load sound (ma_result %i).\n  Path: %s", result, path);
      self->loadResult = 1;
      SoundDesc_CacheDuration(self);
    } else {
      ma_resource_manager_pipeline_notifications notifications = ma_resource_manager_pipeline_notifications_init();
      notifications.done.pNotification = (ma_async_notification*) self->notif;
      ma_result result = ma_resource_manager_data_source_init(rm, path, flags, &notifications, self->ds);
      if (result != MA_SUCCESS)
        Fatal("SoundDesc_Load: Failed to start async load.\n  Path: %s", path);
    }

    RefCounted_Init(self);
  } else {
    RefCounted_Acquire(self);

    if (immediate)
      SoundDesc_FinishLoad(self);
  }

  return self;
}

void SoundDesc_Acquire (SoundDesc* self) {
  RefCounted_Acquire(self);
}

void SoundDesc_Free (SoundDesc* self) {
  RefCounted_Free(self) {
    cstr mapKey = self->mapKey;
    cstr name = self->name;
    cstr path = self->path;
    if (self->notif) {
      MemFree(self->notif);
      self->notif = 0;
    }
    if (self->ds) {
      ma_resource_manager_data_source_uninit(self->ds);
      MemFree(self->ds);
      self->ds = 0;
    }
    Audio_DeallocSoundDesc(self);
    StrFree(mapKey);
    StrFree(name);
    StrFree(path);
  }
}

float SoundDesc_GetDuration (SoundDesc* self) {
  SoundDesc_FinishLoad(self);
  return self->duration;
}

cstr SoundDesc_GetName (SoundDesc* self) {
  return self->name;
}

cstr SoundDesc_GetPath (SoundDesc* self) {
  return self->path;
}

void SoundDesc_ToFile (SoundDesc* self, cstr name) {
  SoundDesc_FinishLoad(self);

  ma_format format;
  uint32 channels;
  uint32 sampleRate;
  ma_result result = ma_resource_manager_data_source_get_data_format(
    self->ds, &format, &channels, &sampleRate, 0, 0);
  if (result != MA_SUCCESS)
    Fatal("SoundDesc_ToFile: Failed to query format.\n  Path: %s", self->path);
  Assert(format == ma_format_f32);

  ma_uint64 length;
  result = ma_resource_manager_data_source_get_length_in_pcm_frames(self->ds, &length);
  if (result != MA_SUCCESS)
    Fatal("SoundDesc_ToFile: Failed to query length.\n  Path: %s", self->path);

  uint32 bitsPerSample = 16;
  uint32 bytesPerSample = bitsPerSample / 8;

  /* Write the file (decoded f32 -> s16 PCM WAV) */ {
    File* file = File_Create(name);
    if (!file)
      Fatal("SoundDesc_ToFile: Failed to create file.\nPath: %s", name);

    File_Write   (file, "RIFF", 4                                                    ); // Chunk ID
    File_WriteI32(file, 36 + (int32) (length * bytesPerSample * channels)            ); // Chunk Size
    File_Write   (file, "WAVE", 4                                                    ); // Wave ID
    File_Write   (file, "fmt ", 4                                                    ); // Chunk ID
    File_WriteI32(file, 16                                                           ); // Chunk Size
    File_WriteI16(file, 1                                                            ); // Format Code (PCM)
    File_WriteI16(file, (int16) channels                                             ); // Channels
    File_WriteI32(file, (int32) sampleRate                                           ); // Sample Rate
    File_WriteI32(file, (int32) (bytesPerSample * channels * sampleRate)             ); // Data Rate
    File_WriteI16(file, (int16) (bytesPerSample * channels)                          ); // Frame Size
    File_WriteI16(file, (int16) bitsPerSample                                        ); // Bits Per Sample
    File_Write   (file, "data", 4                                                    );
    File_WriteI32(file, (int32) (length * bytesPerSample * channels)                 );

    /* Read the decoded source in chunks, converting f32 -> s16. */
    uint32 const framesPerChunk = 4096;
    float buffer[4096 * 8];
    ma_uint64 cursor = 0;
    while (cursor < length) {
      ma_uint64 framesRead = 0;
      ma_uint64 remaining = length - cursor;
      ma_uint64 toRead = remaining < (ma_uint64) framesPerChunk ? remaining : (ma_uint64) framesPerChunk;
      result = ma_resource_manager_data_source_read_pcm_frames(self->ds, buffer, toRead, &framesRead);
      if (result != MA_SUCCESS)
        Fatal("SoundDesc_ToFile: Failed to read decoded data.\n  Path: %s", self->path);
      for (ma_uint64 i = 0; i < framesRead * channels; ++i) {
        float sample = Clamp(buffer[i], -1.0f, 1.0f);
        int16 out = (int16) Round(sample * 32767.0f);
        File_Write(file, &out, sizeof(out));
      }
      cursor += framesRead;
    }

    File_Close(file);
  }
}
