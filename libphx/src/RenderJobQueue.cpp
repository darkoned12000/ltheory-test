#include "RenderJobQueue.h"
#include "DrawBatch.h"
#include "RigidBody.h"
#include "SDL.h"
#include "PhxMemory.h"

struct JobThread {
  RenderJobQueue* queue;
  int index;
  SDL_Thread* handle;
};

struct RenderJobQueue {
  SDL_Mutex* mutex;
  SDL_Condition* have_work;
  SDL_Condition* batch_done;
  JobThread* threads;
  int thread_count;
  /* Current task (set by host under mutex; immutable during task). */
  void** bodies;      /* [count] RigidBody* (opaque; workers cast, disjoint bodies only) */
  DrawJob* out;       /* [count] output records (workers fill matrices; disjoint slices) */
  int count;
  int done_count;
  int generation;     /* task epoch (level-triggered; avoids missed-wakeup deadlock) */
  bool stop;
};

/* Worker: process preassigned contiguous range, signal done. Reads only task
 * snapshot + disjoint bodies (post-update, no writer active); writes only own
 * slice. No GL, no Lua, no allocator. Lock held only for task pickup + done. */
static int RenderJobQueue_Worker (void* data) {
  JobThread* td = (JobThread*)data;
  RenderJobQueue* q = td->queue;
  int seen_gen = 0;
  SDL_LockMutex(q->mutex);
  while (!q->stop) {
    while (!q->stop && q->generation == seen_gen) {
      SDL_WaitCondition(q->have_work, q->mutex);
    }
    if (q->stop) break;
    void** bodies = q->bodies;
    DrawJob* out = q->out;
    int count = q->count;
    int gen = q->generation;
    int idx = td->index;
    int nthreads = q->thread_count;
    seen_gen = gen;
    SDL_UnlockMutex(q->mutex);
    int start = (idx * count) / nthreads;
    int end = ((idx + 1) * count) / nthreads;
    for (int i = start; i < end; ++i) {
      RigidBody* body = (RigidBody*)bodies[i];
      Matrix* mw = RigidBody_GetToWorldMatrix(body);
      out[i].mWorld = *mw;
      Matrix* mi = RigidBody_GetToLocalMatrix(body);
      out[i].mWorldIT = *mi;
    }
    SDL_LockMutex(q->mutex);
    if (gen == q->generation) {
      q->done_count++;
      if (q->done_count >= q->thread_count) {
        SDL_SignalCondition(q->batch_done);
      }
    }
  }
  SDL_UnlockMutex(q->mutex);
  return 0;
}

RenderJobQueue* RenderJobQueue_Create (int workers) {
  if (workers <= 0) {
    int cores = SDL_GetNumLogicalCPUCores();
    if (cores <= 0) cores = 1;
    workers = cores;
    if (workers > 8) workers = 8;  /* cap to avoid oversubscription (Phase 4; tune later) */
  }
  if (workers < 1) workers = 1;
  RenderJobQueue* q = MemNew(RenderJobQueue);
  q->mutex = SDL_CreateMutex();
  q->have_work = SDL_CreateCondition();
  q->batch_done = SDL_CreateCondition();
  if (!q->mutex || !q->have_work || !q->batch_done)
    Fatal("RenderJobQueue_Create: Failed to create sync primitives");
  q->thread_count = workers;
  q->threads = MemNewArray(JobThread, workers);
  q->bodies = 0;
  q->out = 0;
  q->count = 0;
  q->done_count = 0;
  q->generation = 0;
  q->stop = false;
  for (int i = 0; i < workers; ++i) {
    q->threads[i].queue = q;
    q->threads[i].index = i;
    q->threads[i].handle = SDL_CreateThread(RenderJobQueue_Worker, "PHX_RenderJob", (void*)&q->threads[i]);
    if (!q->threads[i].handle)
      Fatal("RenderJobQueue_Create: Failed to start worker thread");
  }
  return q;
}

void RenderJobQueue_BuildBatch (RenderJobQueue* q, void** bodies, DrawJob* out, int count) {
  if (count <= 0) return;
  SDL_LockMutex(q->mutex);
  q->bodies = bodies;
  q->out = out;
  q->count = count;
  q->done_count = 0;
  q->generation++;
  SDL_BroadcastCondition(q->have_work);
  while (q->done_count < q->thread_count) {
    SDL_WaitCondition(q->batch_done, q->mutex);
  }
  SDL_UnlockMutex(q->mutex);
  /* Output fully written; mutex unlock provides happens-before for host replay reads. */
}

void RenderJobQueue_Free (RenderJobQueue* q) {
  /* Call only when no task is active (tasks complete synchronously before replay
   * returns, so idle holds between frames). Never Fatal. */
  SDL_LockMutex(q->mutex);
  q->stop = true;
  SDL_BroadcastCondition(q->have_work);
  SDL_UnlockMutex(q->mutex);
  for (int i = 0; i < q->thread_count; ++i) {
    int ret;
    SDL_WaitThread(q->threads[i].handle, &ret);
  }
  SDL_DestroyCondition(q->have_work);
  SDL_DestroyCondition(q->batch_done);
  SDL_DestroyMutex(q->mutex);
  MemFree(q->threads);
  MemFree(q);
}
