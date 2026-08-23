#pragma once
#include "OpenGL.h"

/* Internal immediate-vertex plumbing shared by Draw.cpp consumers
 * (Tex1D/Tex2D blits, Mesh debug draws). Vertices use the same interleaved
 * layout as Draw.cpp's scratch buffer: [x y z u v] with attribute 0 =
 * position (3f) and attribute 2 = uv (2f).
 *
 * The CALLER is responsible for having the desired program bound and for
 * binding textures to unit 0; these helpers only manage vertex data. */

struct ImmVert { float x, y, z, u, v; };

void Imm_Bind  ();
void Imm_Unbind();
/* Draws verts as the given primitive (QUADS/POLYGON are CPU-expanded to
 * triangles, matching Draw_Flush). Chunks automatically, so count may exceed
 * the internal scratch-buffer capacity. */
void Imm_Draw (ImmVert const* verts, int count, GLenum mode);
