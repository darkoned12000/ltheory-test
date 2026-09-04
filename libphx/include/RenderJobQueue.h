#ifndef PHX_RenderJobQueue
#define PHX_RenderJobQueue

#include "Common.h"
#include "DrawBatch.h"

/* Phase 4: producer/host → persistent workers → host-waits queue for DrawBatch build.
 * Single task type (fill DrawJob matrices from bodies); partitioned by index, order
 * preserved via preassigned disjoint slices. Host calls BuildBatch synchronously
 * (returns when output ready). Graceful shutdown, never Fatal. See §5.4.5, §6.2. */

typedef struct RenderJobQueue RenderJobQueue;

/* workers<=0 → auto via SDL_GetNumLogicalCPUCores, clamped 1..8. Spawns persistent
 * workers (not per-frame) waiting on condvar. Fatal only on thread-create failure
 * at init (startup resource error, matches existing pool); never on teardown. */
PHX_API RenderJobQueue* RenderJobQueue_Create(int workers);

/* Host enqueues build (bodies[RigidBody*] + out[DrawJob] + count), partitions
 * [0,count) contiguously across workers, signals, waits (barrier) until all done.
 * Returns with output fully written (happens-before via mutex). count<=0 returns
 * immediately. Host-thread only; workers must not be active (no concurrent calls). */
PHX_API void RenderJobQueue_BuildBatch(RenderJobQueue* q, void** bodies, DrawJob* out, int count);

/* Graceful shutdown: signal stop, join all workers, free. Never Fatal.
 * Call only when no task is active (tasks complete synchronously before replay
 * returns, so no task is in-flight across frame/reload boundaries). */
PHX_API void RenderJobQueue_Free(RenderJobQueue* q);

#endif
