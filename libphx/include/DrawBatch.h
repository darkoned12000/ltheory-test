#ifndef PHX_DrawBatch
#define PHX_DrawBatch

#include "MatrixDef.h"

/* Phase 3: CPU-side grouped draw submission, single-threaded host replay.
 * DrawJob is POD + opaque pointers only (no Lua userdata/GC pointers inside),
 * so it can be filled from Lua via ffi and later from C++ workers. See §5.4.
 * Field order is padding-safe on x86-64 (8-byte pointers first, then 4-byte
 * fields; total 168 bytes, no padding). LuaJIT ffi cdef must match exactly. */

typedef struct {
  void*  state;       /* ShaderState* (opaque; C++ resolves program + baked uniforms) */
  void*  mesh;        /* Mesh* or LodMesh* (opaque; C++ casts by `split`) */
  Matrix mWorld;      /* per-object world matrix (copied at record; live ptr requires copy) */
  Matrix mWorldIT;    /* per-object world-inverse-transpose (copied at record) */
  int    imWorld;     /* uniform location, or -1 if absent */
  int    imWorldIT;   /* uniform location, or -1 if absent */
  int    iScale;      /* uniform location, or -1 if absent */
  float  scale;       /* per-object scale */
  float  lod;         /* LodMesh distance-squared (ignored for Mesh) */
  int    split;       /* 1 iff Mesh (supports bind/draw split), 0 for LodMesh */
} DrawJob;

/* Host-thread replay only. Groups consecutive same-(state, mesh, split), no
 * reordering. Single-threaded in Phase 3; no threads, no GL off-host.
 * Legacy Mesh_Draw untouched. */
PHX_API void Render_DrawList(const DrawJob* jobs, int count);

/* Pure grouping query for unit tests (no GL). Returns group count; writes start
 * index of each group into out_starts[0..groups-1] (caller provides capacity >=
 * count; groups <= count always; truncates writes but still returns true count
 * if capacity exceeded). Order-preserving, deterministic. Used by Render_DrawList;
 * unit-tested headlessly. */
PHX_API int DrawBatch_GroupRuns(const DrawJob* jobs, int count, int* out_starts, int capacity);

#endif
