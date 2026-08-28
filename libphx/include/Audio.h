#ifndef PHX_Audio
#define PHX_Audio

#include "Common.h"

PHX_API void        Audio_Init               ();
PHX_API void        Audio_Free               ();

PHX_API void        Audio_AttachListenerPos  (Vec3f const* pos, Vec3f const* vel, Vec3f const* fwd, Vec3f const* up);
PHX_API void        Audio_Set3DSettings      (float doppler, float scale, float rolloff);
PHX_API void        Audio_SetListenerPos     (Vec3f const* pos, Vec3f const* vel, Vec3f const* fwd, Vec3f const* up);
PHX_API void        Audio_Update             ();

/* --- Debug API ------------------------------------------------------------ */

PHX_API int32       Audio_GetLoadedCount     ();
PHX_API int32       Audio_GetPlayingCount    ();
PHX_API int32       Audio_GetTotalCount      ();

/* --- Private API ---------------------------------------------------------- */

PRIVATE void*       Audio_GetHandle          ();
PRIVATE float       Audio_GetDoppler         ();
PRIVATE float       Audio_GetScale           ();
PRIVATE float       Audio_GetRolloff         ();
PRIVATE SoundDesc*  Audio_AllocSoundDesc     (cstr name);
PRIVATE void        Audio_DeallocSoundDesc   (SoundDesc*);
PRIVATE Sound*      Audio_AllocSound         ();
PRIVATE void        Audio_DeallocSound       (Sound*);
PRIVATE void        Audio_SoundStateChanged  (Sound*);

#endif

/* NOTE : Primary */
/* TODO : Investigate HRTF (miniaudio's spatializer is panned stereo; OpenAL
 *        Soft-style HRTF binaural output would need a custom node) */

/* NOTE : Secondary */
/* TODO : What happens when there is no audio device or the audio device is disconnected? */
/* TODO : Finish Sound_ToFile */
/* TODO : Respect the default device if it changes at runtime. miniaudio's
 *        device enumeration + a re-route handler would be needed. */

/* NOTE : If we ever decide to use streams (MA_RESOURCE_MANAGER_DATA_SOURCE_FLAG_STREAM)
 *        all sound APIs must be carefully updated to support it. In those
 *        cases sounds have additional readiness states we don't currently handle. */
