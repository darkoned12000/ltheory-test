#include "DrawBatch.h"
#include "LodMesh.h"
#include "Mesh.h"
#include "PhxMemory.h"
#include "Shader.h"
#include "ShaderState.h"

static_assert(sizeof(DrawJob) == 168, "DrawJob ABI mismatch: C++ and Lua ffi cdef must match exactly");

/* Phase 3: host-thread grouped replay, single-threaded. Mirrors Batcher.replay
 * (Lua) exactly: consecutive same-(state, mesh, split) runs, original order
 * preserved, no reordering. Program start + bind amortized to once per run.
 * Legacy Mesh_Draw / LodMesh_Draw paths untouched. No threads; host only. */

int DrawBatch_GroupRuns (const DrawJob* jobs, int count, int* out_starts, int capacity) {
  int groups = 0;
  int i = 0;
  while (i < count) {
    if (groups < capacity) out_starts[groups] = i;
    groups++;
    const DrawJob* first = &jobs[i];
    int j = i;
    while (j + 1 < count
      && jobs[j+1].state == first->state
      && jobs[j+1].mesh  == first->mesh
      && jobs[j+1].split == first->split) {
      ++j;
    }
    i = j + 1;
  }
  return groups;
}

void Render_DrawList (const DrawJob* jobs, int count) {
  if (count <= 0) return;
  int* starts = MemNewArray(int, count);
  int groups = DrawBatch_GroupRuns(jobs, count, starts, count);
  for (int g = 0; g < groups; ++g) {
    int i = starts[g];
    int j = (g + 1 < groups) ? (starts[g+1] - 1) : (count - 1);
    const DrawJob* first = &jobs[i];
    /* Replay run [i..j]. Lua guarantees no onStart materials are recorded
     * (callers fall back to legacy immediate draw), so no callback check here. */
    ShaderState* st = (ShaderState*)first->state;
    ShaderState_Start(st);
    if (first->split) {
      Mesh* m = (Mesh*)first->mesh;
      Mesh_DrawBind(m);
      for (int k = i; k <= j; ++k) {
        const DrawJob* job = &jobs[k];
        if (job->imWorld   != -1) Shader_ISetMatrix (job->imWorld,   (Matrix*)&job->mWorld);
        if (job->imWorldIT != -1) Shader_ISetMatrixT(job->imWorldIT, (Matrix*)&job->mWorldIT);
        if (job->iScale    != -1) Shader_ISetFloat  (job->iScale,    job->scale);
        Mesh_DrawBound(m);
      }
      Mesh_DrawUnbind(m);
    } else {
      for (int k = i; k <= j; ++k) {
        const DrawJob* job = &jobs[k];
        if (job->imWorld   != -1) Shader_ISetMatrix (job->imWorld,   (Matrix*)&job->mWorld);
        if (job->imWorldIT != -1) Shader_ISetMatrixT(job->imWorldIT, (Matrix*)&job->mWorldIT);
        if (job->iScale    != -1) Shader_ISetFloat  (job->iScale,    job->scale);
        LodMesh_Draw((LodMesh*)job->mesh, job->lod);
      }
    }
    ShaderState_Stop(st);
  }
  MemFree(starts);
}
