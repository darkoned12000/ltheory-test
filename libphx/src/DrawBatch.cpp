#include "DrawBatch.h"
#include "LodMesh.h"
#include "Mesh.h"
#include "Shader.h"
#include "ShaderState.h"

/* Phase 3: host-thread grouped replay, single-threaded. Mirrors Batcher.replay
 * (Lua) exactly: consecutive same-(state, mesh, split) runs, original order
 * preserved, no reordering. Program start + bind amortized to once per run.
 * Legacy Mesh_Draw / LodMesh_Draw paths untouched. No threads; host only. */

void Render_DrawList (const DrawJob* jobs, int count) {
  int i = 0;
  while (i < count) {
    const DrawJob* first = &jobs[i];
    int j = i;
    while (j + 1 < count
      && jobs[j+1].state == first->state
      && jobs[j+1].mesh  == first->mesh
      && jobs[j+1].split == first->split) {
      ++j;
    }
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
    i = j + 1;
  }
}
