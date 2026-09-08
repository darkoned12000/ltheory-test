#include "Draw.h"
#include "DrawInternal.h"
#include "BlendMode.h"
#include "DataFormat.h"
#include "Metric.h"
#include "OpenGL.h"
#include "PixelFormat.h"
#include "Shader.h"
#include "ShaderVar.h"
#include "ShaderVarType.h"
#include "Tex2D.h"
#include "TexFormat.h"
#include "Vec4.h"
#include <cstring>

/* ----------------------------------------------------------------------------
 * Draw subsystem — modernized to VBO instead of deprecated immediate mode
 * (glBegin / glVertex / glTexCoord), which is unavailable under a GL core
 * profile. Every Draw_* function now appends vertices to a scratch buffer,
 * uploads it to a single dynamic VBO, binds the position/uv attributes
 * (locations 0 and 2, matching libphx/src/Mesh.cpp), draws, and unbinds.
 *
 * Vertex layout (interleaved, 5 floats):
 *   [0..2] position -> attribute location 0  (vertex_position)
 *   [3..4] uv       -> attribute location 2  (vertex_uv)
 *
 * All Draw_* vertex shaders read these real attributes (the legacy
 * gl_Vertex / gl_MultiTexCoord0 built-ins have been removed — see
 * AGENTS.md "GLSL upgrade" notes). The draw pattern mirrors Mesh.cpp's
 * DrawBind/DrawUnbind so VAO/attrib state is managed identically.
 * -------------------------------------------------------------------------- */

#define MAX_STACK_DEPTH 16

/* Interleaved vertex: position (xyz) + uv. */
typedef struct {
  float x, y, z;
  float u, v;
} DrawVert;

/* Scratch buffer — large enough for the biggest immediate primitive (sphere). */
#define DRAW_MAX_VERTS (4096)
static DrawVert  s_verts[DRAW_MAX_VERTS];
static int       s_count = 0;
static GLuint    s_vbo   = 0;
static bool      s_init  = false;

static float alphaStack[MAX_STACK_DEPTH];
static int alphaIndex = -1;
static Vec4f color = { 1, 1, 1, 1 };

/* --- Default program for legacy color-state draws --------------------------------
 * Core profile rasterizes nothing when no program is bound (AGENTS.md trap #2).
 * The pre-migration engine relied on fixed-function for Font_Draw glyphs, raw
 * Draw.Rect/Tri/Line color primitives, and Tex2D blits. Draw_Flush now starts a
 * generic flat program (color * unit-0 texture) for those when nothing is bound:
 *   - flat draws get the engine's 1x1 white dummy texture -> pure Draw_Color
 *   - textured blits (Tex2D_Draw/DrawEx) keep their unit-0 binding
 * The color uniform replicates the old glColor4f(r, g, b, a * alphaStack).
 * Calls made under an explicitly-started program are untouched. */
static Shader* s_progFlat = nullptr;
static Tex2D*  s_texWhite = nullptr;
static bool    s_lastTextured = false;

void Draw_SetTexturedImm (bool textured) {
  s_lastTextured = textured;
}

static void Draw_Init () {
  if (s_init) return;
  s_init = true;
  GLCALL(glGenBuffers(1, &s_vbo));
  /* 1x1 white texture: sampling it under the flat program yields the raw
   * Draw_Color, matching the old untextured fixed-function result. */
  s_texWhite = Tex2D_Create(1, 1, TexFormat_RGBA8);
  float white[4] = { 1.0f, 1.0f, 1.0f, 1.0f };
  Tex2D_SetData(s_texWhite, white, PixelFormat_RGBA, DataFormat_Float);
}

void Draw_DrawArraysInstanced (int mode, int first, int count, int primcount) {
  /* FRAME_BEGIN is intentionally omitted: callers drive their own profiling,
   * and this draws nothing from the Imm_ scratch buffers. */
  GLCALL(glDrawArraysInstanced((GLenum)mode, first, count, primcount))
}

/* Bind the VBO + attribute arrays for drawing. Mirrors Mesh_DrawBind. */
static void Draw_Bind () {
  Draw_Init();
  GLCALL(glBindBuffer(GL_ARRAY_BUFFER, s_vbo));
  GLCALL(glEnableVertexAttribArray(0));
  GLCALL(glVertexAttribPointer(0, 3, GL_FLOAT, false, sizeof(DrawVert), (void const*)OFFSET_OF(DrawVert, x)));
  GLCALL(glEnableVertexAttribArray(2));
  GLCALL(glVertexAttribPointer(2, 2, GL_FLOAT, false, sizeof(DrawVert), (void const*)OFFSET_OF(DrawVert, u)));
}

/* Unbind. Mirrors Mesh_DrawUnbind. */
static void Draw_Unbind () {
  GLCALL(glDisableVertexAttribArray(0));
  GLCALL(glDisableVertexAttribArray(2));
  GLCALL(glBindBuffer(GL_ARRAY_BUFFER, 0));
}

static inline void Draw_Push (float x, float y, float z = 0.0f, float u = 0.0f, float v = 0.0f) {
  if (s_count >= DRAW_MAX_VERTS) return;
  DrawVert* p = &s_verts[s_count++];
  p->x = x; p->y = y; p->z = z;
  p->u = u; p->v = v;
}

/* Upload the scratch buffer and draw it as the given GL primitive.
 * QUADS / POLYGON are expanded into triangles on the CPU (matching the
 * previous immediate-mode expansion). */
/* Expand buffered verts of the given primitive into a plain triangle list
 * (GL_TRIANGLES) in a SEPARATE scratch buffer, so a single glDrawArrays can
 * render everything. Using a second buffer avoids any in-place read/write
 * overlap (a 4-vert quad expands to 6 verts; expanding in place corrupts
 * later source verts). Matches the old immediate-mode expansion exactly. */
static DrawVert s_expand[DRAW_MAX_VERTS * 2];
static int Draw_Expand (GLenum mode) {
  if (mode == GL_QUADS) {
    int quads = s_count / 4;
    int out = 0;
    for (int q = 0; q < quads; ++q) {
      DrawVert* v = &s_verts[q * 4];
      /* Tri A: v0, v1, v2   Tri B: v0, v2, v3  (fan from v0). */
      s_expand[out++] = v[0];
      s_expand[out++] = v[1];
      s_expand[out++] = v[2];
      s_expand[out++] = v[0];
      s_expand[out++] = v[2];
      s_expand[out++] = v[3];
    }
    memcpy(s_verts, s_expand, (size_t)out * sizeof(DrawVert));
    s_count = out;
    return GL_TRIANGLES;
  }
  if (mode == GL_POLYGON) {
    int out = 0;
    for (int i = 1; i < s_count - 1; ++i) {
      s_expand[out++] = s_verts[0];
      s_expand[out++] = s_verts[i];
      s_expand[out++] = s_verts[i + 1];
    }
    memcpy(s_verts, s_expand, (size_t)out * sizeof(DrawVert));
    s_count = out;
    return GL_TRIANGLES;
  }
  return mode; /* LINES / POINTS / TRIANGLES unchanged */
}

/* --- Deferred flat batch -----------------------------------------------------
 * The color-state path (Draw_Rect/Line/Tri/... with no explicitly-started
 * program and no texture blit — DIRECTLY the debug-panel/widget path) queues
 * primitives into s_verts instead of one glDraw per primitive. A queued
 * run stays pending until its signature changes or a state boundary forces a
 * commit, so e.g. the panel's ~5,000 same-color rects become a handful of
 * draws (roadmap #15).
 *
 * Run signature: GL mode, run color (alpha stack already baked in), and the
 * textured flag. Commit points:
 *   - signature change (mode / color / alpha / textured),
 *   - an explicitly-started program (Shader_GetActive()) or a texture blit
 *     (s_lastTextured) — those take the legacy one-shot path,
 *   - RenderState / RenderTarget / Shader_Start / line+point-size / swap
 *     boundaries, via Draw_FlushPending() (see RenderState.cpp, Shader.cpp,
 *     RenderTarget.cpp, Window.cpp),
 *   - vertex-buffer overflow (commit and continue the run in a new slice).
 *
 * Queue order is preserved both within a run and across commits, so blending
 * order is identical to the old per-primitive flush.
 * -------------------------------------------------------------------------- */
static GLenum s_batchMode = 0;        /* Pending run primitive; 0 = idle.    */
static bool   s_batchTextured = false;
static float  s_batchR = 1, s_batchG = 1, s_batchB = 1, s_batchA = 1;

static inline float Draw_CurrentAlpha () {
  return color.w * (alphaIndex >= 0 ? alphaStack[alphaIndex] : 1.0f);
}

/* Upload the pending verts and draw them as the given primitive. Mirrors the
 * old per-primitive Draw_Flush(GLenum): expands QUADS/POLYGON, starts the flat
 * program when nothing is active, binds the white dummy texture for flat runs,
 * and counts the actual IMM draw that happened. */
static void Draw_Emit (GLenum mode) {
  if (s_count == 0) return;

  mode = Draw_Expand(mode);
  int verts = s_count;
  int tris  = (mode == GL_TRIANGLES) ? verts / 3 : 0;

  bool startedDefault = false;
  if (!Shader_GetActive()) {
    if (!s_progFlat)
      s_progFlat = Shader_Load("vertex/ui", "fragment/ui/flat");
    if (s_progFlat && ShaderVar_Get("mProjUI", ShaderVarType_Matrix)) {
      Shader_Start(s_progFlat);
      /* Old semantics: glColor4f(r, g, b, a * alphaStackTop). */
      Shader_SetFloat4("color", s_batchR, s_batchG, s_batchB, s_batchA);
      if (!s_batchTextured) {
        /* Flat primitive: neutralize whatever is on unit 0. */
        GLCALL(glActiveTexture(GL_TEXTURE0))
        GLCALL(glBindTexture(GL_TEXTURE_2D, Tex2D_GetHandle(s_texWhite)))
      }
      startedDefault = true;
    }
    /* else: no flat program (broken load) or no viewport matrices pushed —
     * skip silently, exactly as the core-profile no-program behavior did. */
  }

  if (Shader_GetActive()) {
    Draw_Bind();
    GLCALL(glBufferData(GL_ARRAY_BUFFER, (GLsizeiptr)(s_count * (int)sizeof(DrawVert)), s_verts, GL_DYNAMIC_DRAW));
    GLCALL(glDrawArrays(mode, 0, s_count));
    Draw_Unbind();
  }

  if (startedDefault) Shader_Stop(nullptr);
  s_count = 0;
  s_lastTextured = false;
  Metric_AddDrawImm(1, tris, verts);
}

/* Emit the pending run (if any) and clear the run state. */
static void Draw_Commit () {
  if (s_batchMode) {
    GLenum mode = s_batchMode;
    s_batchMode = 0;
    Draw_Emit(mode);
  }
}

/* --- Widget batch (roadmap #15) -- forward decl, defined below. ------------- */
static void Draw_WidgetFlush ();

/* Exported: commit queued immediate geometry now, without glFinish. Hooked at
 * render-target / program / render-state / swap boundaries so a deferred run
 * is always emitted under the GL state it was queued in. */
void Draw_FlushPending () {
  Draw_Commit();
  Draw_WidgetFlush();
}

/* Pure run-signature comparison (see Draw.h). Exact float equality: a run only
 * continues when mode and the queued color * baked-alpha key are bit-identical;
 * anything else commits first — always safe, occasionally just less merging. */
int ImmBatch_KeyMatch (
  int modeA, float rA, float gA, float bA, float aA,
  int modeB, float rB, float gB, float bB, float aB)
{
  return modeA == modeB
      && rA == rB && gA == gB && bA == bB && aA == aB;
}

/* Queue src[0..count) into the deferred flat run, or take the legacy one-shot
 * path when an explicit program or texture blit is in flight. */
static void Draw_Enqueue (DrawVert const* src, int count, GLenum mode) {
  if (count <= 0) return;

  Draw_WidgetFlush();   /* Widgets queued earlier draw before this flat rect. */

  if (Shader_GetActive() || s_lastTextured) {
    Draw_Commit();
    s_batchTextured = s_lastTextured;
    s_batchR = color.x; s_batchG = color.y; s_batchB = color.z;
    s_batchA = Draw_CurrentAlpha();
    while (count > 0) {
      int n = count < DRAW_MAX_VERTS ? count : DRAW_MAX_VERTS;
      memcpy(s_verts, src, (size_t)n * sizeof(DrawVert));
      s_count = n;
      Draw_Emit(mode);
      src += n;
      count -= n;
    }
    return;
  }

  float a = Draw_CurrentAlpha();
  if (s_batchMode != 0
      && !ImmBatch_KeyMatch(s_batchMode, s_batchR, s_batchG, s_batchB, s_batchA,
                            mode, color.x, color.y, color.z, a)) {
    Draw_Commit();
  }
  if (s_batchMode == 0) {
    s_batchMode = mode;
    s_batchR = color.x; s_batchG = color.y; s_batchB = color.z; s_batchA = a;
    s_batchTextured = false;
  }

  int in = 0;
  while (in < count) {
    if (s_count >= DRAW_MAX_VERTS) {
      Draw_Commit();
      s_batchMode = mode;
      s_batchR = color.x; s_batchG = color.y; s_batchB = color.z; s_batchA = a;
      s_batchTextured = false;
    }
    int room = DRAW_MAX_VERTS - s_count;
    int c = count - in;
    if (c > room) c = room;
    memcpy(s_verts + s_count, src + in, (size_t)c * sizeof(DrawVert));
    s_count += c;
    in += c;
  }
}

void Imm_Bind () {
  Draw_Bind();
}

void Imm_Unbind () {
  Draw_Unbind();
}

/* Raw vertex-stream blits (Tex1D/Tex2D/DebugMesh). Flushes any pending run
 * first so the blit lands in queue order, then emits the stream directly. */
void Imm_Draw (ImmVert const* verts, int count, GLenum mode) {
  if (!verts || count <= 0) return;
  Draw_WidgetFlush();   /* Textured blits (font/text) draw after queued widgets. */
  Draw_Commit();
  s_batchTextured = s_lastTextured;
  s_batchR = color.x; s_batchG = color.y; s_batchB = color.z;
  s_batchA = Draw_CurrentAlpha();
  while (count > 0) {
    int n = count < DRAW_MAX_VERTS ? count : DRAW_MAX_VERTS;
    memcpy(s_verts, verts, (size_t)n * sizeof(DrawVert));
    s_count = n;
    Draw_Emit(mode);
    verts += n;
    count -= n;
  }
}

/* --- Widget batch ------------------------------------------------------------
 * DrawEx.Rect/Line/Panel/Ring (SDF widget shaders) each used to start a
 * program, upload per-rect uniforms, draw one padded quad, and stop — ~1,460
 * program start/stops per frame on the debug panel. Here those uniforms and the
 * color travel as per-vertex attributes (WidgetVert below), so consecutive
 * rects sharing a (shader, blend) run merge into ONE glDrawArrays under a
 * single program start (roadmap #15). Queue order is preserved both within a
 * run and across commits; blend is applied per-run and the ambient GL blend
 * restored, so overdraw layering is bit-identical to the old per-rect calls.
 *
 * Run key: widget shader enum + blend mode. Commit points:
 *   - key change, VBO overflow (commit and continue),
 *   - any non-widget draw or state boundary via Draw_WidgetFlush(): flat
 *     Draw_Enqueue, Imm_Draw (font/text blits), Draw_FlushPending
 *     (RenderState/RenderTarget/Shader_Start/ShaderVar/Window boundaries).
 * -------------------------------------------------------------------------- */
#define WIDGET_MAX_VERTS (4096)
typedef struct {
  float x, y, z;            /* UI-space corner (padded bbox, like Draw_Rect). */
  float u, v;               /* 0..1 over the quad. */
  float r, g, b, a;         /* per-rect color (matches the old color uniform). */
  float pa0, pa1, pa2, pa3; /* SDF parameters, bank A. */
  float pb0, pb1, pb2, pb3; /* SDF parameters, bank B. */
} WidgetVert;

static WidgetVert s_wVerts[WIDGET_MAX_VERTS];
static int        s_wCount = 0;
static GLuint     s_wVbo   = 0;

static int    s_wShader = -1;                       /* Run key: shader enum. */
static BlendMode s_wBlend = BlendMode_Additive;     /* Run key: blend. */
static bool   s_wFlushing = false;

static char const* const s_wFrag[WidgetShader_Ring + 1] = {
  "fragment/ui/box", "fragment/ui/line", "fragment/ui/panel", "fragment/ui/ring",
};
static Shader* s_wProg[WidgetShader_Ring + 1] = { nullptr, nullptr, nullptr, nullptr };

static void Draw_WidgetBind () {
  if (!s_wVbo) GLCALL(glGenBuffers(1, &s_wVbo));
  GLCALL(glBindBuffer(GL_ARRAY_BUFFER, s_wVbo))
  GLCALL(glEnableVertexAttribArray(0))
  GLCALL(glEnableVertexAttribArray(2))
  GLCALL(glEnableVertexAttribArray(3))
  GLCALL(glEnableVertexAttribArray(4))
  GLCALL(glEnableVertexAttribArray(5))
  GLCALL(glVertexAttribPointer(0, 3, GL_FLOAT, false, sizeof(WidgetVert), (void const*)OFFSET_OF(WidgetVert, x)))
  GLCALL(glVertexAttribPointer(2, 2, GL_FLOAT, false, sizeof(WidgetVert), (void const*)OFFSET_OF(WidgetVert, u)))
  GLCALL(glVertexAttribPointer(3, 4, GL_FLOAT, false, sizeof(WidgetVert), (void const*)OFFSET_OF(WidgetVert, r)))
  GLCALL(glVertexAttribPointer(4, 4, GL_FLOAT, false, sizeof(WidgetVert), (void const*)OFFSET_OF(WidgetVert, pa0)))
  GLCALL(glVertexAttribPointer(5, 4, GL_FLOAT, false, sizeof(WidgetVert), (void const*)OFFSET_OF(WidgetVert, pb0)))
}

static void Draw_WidgetUnbind () {
  GLCALL(glDisableVertexAttribArray(5))
  GLCALL(glDisableVertexAttribArray(4))
  GLCALL(glDisableVertexAttribArray(3))
  GLCALL(glDisableVertexAttribArray(2))
  GLCALL(glDisableVertexAttribArray(0))
  GLCALL(glBindBuffer(GL_ARRAY_BUFFER, 0))
}

inline static void Draw_WidgetSetBlend (BlendMode mode) {
  switch (mode) {
    case BlendMode_Additive:
      GLCALL(glBlendFuncSeparate(GL_ONE, GL_ONE, GL_ONE, GL_ONE))
      break;
    case BlendMode_Alpha:
      GLCALL(glBlendFuncSeparate(
        GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA,
        GL_ONE, GL_ONE_MINUS_SRC_ALPHA))
      break;
    default:
      break;
  }
}

inline static void Draw_WidgetRestoreBlend (GLint const blend[4]) {
  GLCALL(glBlendFuncSeparate(blend[0], blend[1], blend[2], blend[3]))
}

/* Upload the pending widget run and draw it under its program. */
static void Draw_WidgetEmit () {
  int count = s_wCount;
  int shaderIdx = s_wShader;
  BlendMode blend = s_wBlend;
  s_wCount = 0;
  s_wShader = -1;
  if (count == 0) return;
  if (shaderIdx < WidgetShader_Box || shaderIdx > WidgetShader_Ring) return;

  if (!s_wProg[shaderIdx])
    s_wProg[shaderIdx] = Shader_Load("vertex/ui/widget", s_wFrag[shaderIdx]);
  if (!s_wProg[shaderIdx]) return;
  if (!ShaderVar_Get("mProjUI", ShaderVarType_Matrix)) return;  /* No UI viewport. */

  /* Preserve the ambient GL blend (the UI pass' Alpha base). */
  GLint ambient[4];
  GLCALL(glGetIntegerv(GL_BLEND_SRC_RGB,   &ambient[0]))
  GLCALL(glGetIntegerv(GL_BLEND_DST_RGB,   &ambient[1]))
  GLCALL(glGetIntegerv(GL_BLEND_SRC_ALPHA, &ambient[2]))
  GLCALL(glGetIntegerv(GL_BLEND_DST_ALPHA, &ambient[3]))

  Shader* prevActive = Shader_GetActive();
  Shader_Start(s_wProg[shaderIdx]);
  Draw_WidgetSetBlend(blend);

  Draw_WidgetBind();
  GLCALL(glBufferData(GL_ARRAY_BUFFER, (GLsizeiptr)(count * (int)sizeof(WidgetVert)), s_wVerts, GL_DYNAMIC_DRAW))
  GLCALL(glDrawArrays(GL_TRIANGLES, 0, count))
  Draw_WidgetUnbind();

  Draw_WidgetRestoreBlend(ambient);
  Shader_Stop(nullptr);
  if (prevActive) Shader_Start(prevActive);

  Metric_AddDrawImm(1, count / 3, count);
}

/* Emit the pending widget run (if any) and clear the run state. Reentrancy-
 * guarded: emitting starts a program (Shader_Start -> Draw_FlushPending). */
static void Draw_WidgetFlush () {
  if (s_wFlushing) return;
  s_wFlushing = true;
  Draw_WidgetEmit();
  s_wFlushing = false;
}

void Draw_WidgetRect (
  int shader, int blend,
  float x, float y, float sx, float sy,
  float r, float g, float b, float a,
  float pa0, float pa1, float pa2, float pa3,
  float pb0, float pb1, float pb2, float pb3)
{
  Draw_Commit();   /* Flat prims queued earlier draw before these widgets. */
  if (s_wShader != shader || s_wBlend != (BlendMode)blend) Draw_WidgetFlush();
  if (s_wCount == 0) {
    s_wShader = shader;
    s_wBlend = (BlendMode)blend;
  }
  if (s_wCount + 6 > WIDGET_MAX_VERTS) {
    Draw_WidgetFlush();
    s_wShader = shader;
    s_wBlend = (BlendMode)blend;
  }

  /* One padded quad -> two triangles, UVs 0..1, same expansion as Draw_Emit. */
  float x2 = x + sx;
  float y2 = y + sy;
#define W_VERT(cx, cy, cu, cv)                                                 \
  WidgetVert{ (cx), (cy), 0.0f, (cu), (cv), r, g, b, a,                       \
              pa0, pa1, pa2, pa3, pb0, pb1, pb2, pb3 }
  WidgetVert v[6] = {
    W_VERT(x,  y,  0, 0), W_VERT(x,  y2, 0, 1), W_VERT(x2, y2, 1, 1),
    W_VERT(x,  y,  0, 0), W_VERT(x2, y2, 1, 1), W_VERT(x2, y,  1, 0),
  };
#undef W_VERT
  memcpy(s_wVerts + s_wCount, v, sizeof(v));
  s_wCount += 6;
}

void Draw_PushAlpha (float a) {
  if (alphaIndex + 1 >= MAX_STACK_DEPTH)
      Fatal("Draw_PushAlpha: Maximum alpha stack depth exceeded");

  float prevAlpha = alphaIndex >= 0 ? alphaStack[alphaIndex] : 1;
  float alpha = a * prevAlpha;
  alphaStack[++alphaIndex] = alpha;
}

void Draw_PopAlpha () {
  if (alphaIndex < 0)
      Fatal("Draw_PopAlpha Attempting to pop an empty alpha stack");

  alphaIndex--;
}

void Draw_Axes (
  Vec3f const* pos,
  Vec3f const* x,
  Vec3f const* y,
  Vec3f const* z,
  float scale,
  float _alpha)
{
  Vec3f left    = Vec3f_Add(*pos, Vec3f_Muls(*x, scale));
  Vec3f up      = Vec3f_Add(*pos, Vec3f_Muls(*y, scale));
  Vec3f forward = Vec3f_Add(*pos, Vec3f_Muls(*z, scale));
  DrawVert lines[6] = {
    { UNPACK3(*pos), 0, 0 }, { UNPACK3(left), 0, 0 },
    { UNPACK3(*pos), 0, 0 }, { UNPACK3(up), 0, 0 },
    { UNPACK3(*pos), 0, 0 }, { UNPACK3(forward), 0, 0 },
  };
  DrawVert center[1] = { { UNPACK3(*pos), 0, 0 } };
  Draw_Enqueue(lines, 6, GL_LINES);
  Draw_Enqueue(center, 1, GL_POINTS);
}

void Draw_Border (float s, float x, float y, float w, float h) {
  Draw_Rect(x, y, w, s);
  Draw_Rect(x, y + h - s, w, s);
  Draw_Rect(x, y + s, s, h - 2*s);
  Draw_Rect(x + w - s, y + s, s, h - 2*s);
}

void Draw_Box3 (Box3f const* self) {
  DrawVert v[24] = {
    /* Left. */
    { self->lower.x, self->lower.y, self->lower.z, 0, 0 },
    { self->lower.x, self->lower.y, self->upper.z, 0, 0 },
    { self->lower.x, self->upper.y, self->upper.z, 0, 0 },
    { self->lower.x, self->upper.y, self->lower.z, 0, 0 },
    /* Right. */
    { self->upper.x, self->lower.y, self->lower.z, 0, 0 },
    { self->upper.x, self->upper.y, self->lower.z, 0, 0 },
    { self->upper.x, self->upper.y, self->upper.z, 0, 0 },
    { self->upper.x, self->lower.y, self->upper.z, 0, 0 },
    /* Front. */
    { self->lower.x, self->lower.y, self->upper.z, 0, 0 },
    { self->upper.x, self->lower.y, self->upper.z, 0, 0 },
    { self->upper.x, self->upper.y, self->upper.z, 0, 0 },
    { self->lower.x, self->upper.y, self->upper.z, 0, 0 },
    /* Back. */
    { self->lower.x, self->lower.y, self->lower.z, 0, 0 },
    { self->lower.x, self->upper.y, self->lower.z, 0, 0 },
    { self->upper.x, self->upper.y, self->lower.z, 0, 0 },
    { self->upper.x, self->lower.y, self->lower.z, 0, 0 },
    /* Top. */
    { self->lower.x, self->upper.y, self->lower.z, 0, 0 },
    { self->lower.x, self->upper.y, self->upper.z, 0, 0 },
    { self->upper.x, self->upper.y, self->upper.z, 0, 0 },
    { self->upper.x, self->upper.y, self->lower.z, 0, 0 },
    /* Bottom. */
    { self->lower.x, self->lower.y, self->lower.z, 0, 0 },
    { self->upper.x, self->lower.y, self->lower.z, 0, 0 },
    { self->upper.x, self->lower.y, self->upper.z, 0, 0 },
    { self->lower.x, self->lower.y, self->upper.z, 0, 0 },
  };
  Draw_Enqueue(v, 24, GL_QUADS);
}

void Draw_Clear (float r, float g, float b, float a) {
  GLCALL(glClearColor(r, g, b, a))
  GLCALL(glClear(GL_COLOR_BUFFER_BIT))
}

void Draw_ClearDepth (float d) {
  GLCALL(glClearDepth(d))
  GLCALL(glClear(GL_DEPTH_BUFFER_BIT))
}

void Draw_Color (float r, float g, float b, float a) {
  float alpha = alphaIndex >= 0 ? alphaStack[alphaIndex] : 1;
  color = Vec4f_Create(r, g, b, a);
}

void Draw_Flush () {
  Draw_Commit();
  Draw_WidgetFlush();
  Metric_Inc(Metric_Flush);
  GLCALL(glFinish())
}

void Draw_Line (float x1, float y1, float x2, float y2) {
  DrawVert v[2] = { { x1, y1, 0, 0, 0 }, { x2, y2, 0, 0, 0 } };
  Draw_Enqueue(v, 2, GL_LINES);
}

void Draw_Line3 (Vec3f const* p1, Vec3f const* p2) {
  DrawVert v[2] = { { UNPACK3(*p1), 0, 0 }, { UNPACK3(*p2), 0, 0 } };
  Draw_Enqueue(v, 2, GL_LINES);
}

void Draw_LineWidth (float width) {
  Draw_Commit();
  GLCALL(glLineWidth(width))
}

void Draw_Plane (Vec3f const* p, Vec3f const* n, float scale) {
  Vec3f e1 = Abs(n->x) < 0.7f ? Vec3f_Create(1, 0, 0) : Vec3f_Create(0, 1, 0);
  e1 = Vec3f_Normalize(Vec3f_Reject(e1, *n));
  Vec3f e2 = Vec3f_Cross(*n, e1);

  Vec3f p0 = Vec3f_Add(*p, Vec3f_Add(Vec3f_Muls(e1, -scale), Vec3f_Muls(e2, -scale)));
  Vec3f p1 = Vec3f_Add(*p, Vec3f_Add(Vec3f_Muls(e1,  scale), Vec3f_Muls(e2, -scale)));
  Vec3f p2 = Vec3f_Add(*p, Vec3f_Add(Vec3f_Muls(e1,  scale), Vec3f_Muls(e2,  scale)));
  Vec3f p3 = Vec3f_Add(*p, Vec3f_Add(Vec3f_Muls(e1, -scale), Vec3f_Muls(e2,  scale)));

  DrawVert v[4] = {
    { UNPACK3(p0), 0, 0 }, { UNPACK3(p1), 0, 0 },
    { UNPACK3(p2), 0, 0 }, { UNPACK3(p3), 0, 0 },
  };
  Draw_Enqueue(v, 4, GL_QUADS);
}

void Draw_Point (float x, float y) {
  DrawVert v[1] = { { x, y, 0, 0, 0 } };
  Draw_Enqueue(v, 1, GL_POINTS);
}

void Draw_Point3 (float x, float y, float z) {
  DrawVert v[1] = { { x, y, z, 0, 0 } };
  Draw_Enqueue(v, 1, GL_POINTS);
}

void Draw_PointSize (float size) {
  Draw_Commit();
  GLCALL(glPointSize(size))
}

void Draw_Poly (Vec2f const* points, int count) {
  if (count <= 1) return;
  if (count > DRAW_MAX_VERTS) count = DRAW_MAX_VERTS;
  DrawVert v[DRAW_MAX_VERTS];
  for (int i = 0; i < count; ++i)
    v[i] = DrawVert{ UNPACK2(points[i]), 0, 0 };
  Draw_Enqueue(v, count, GL_POLYGON);
}

void Draw_Poly3 (Vec3f const* points, int count) {
  if (count <= 1) return;
  if (count > DRAW_MAX_VERTS) count = DRAW_MAX_VERTS;
  DrawVert v[DRAW_MAX_VERTS];
  for (int i = 0; i < count; ++i)
    v[i] = DrawVert{ UNPACK3(points[i]), 0, 0 };
  Draw_Enqueue(v, count, GL_POLYGON);
}

void Draw_Quad (Vec2f const* p1, Vec2f const* p2, Vec2f const* p3, Vec2f const* p4) {
  DrawVert v[4] = {
    { UNPACK2(*p1), 0, 0 }, { UNPACK2(*p2), 0, 1 },
    { UNPACK2(*p3), 1, 1 }, { UNPACK2(*p4), 1, 0 },
  };
  Draw_Enqueue(v, 4, GL_QUADS);
}

void Draw_Quad3 (Vec3f const* p1, Vec3f const* p2, Vec3f const* p3, Vec3f const* p4) {
  DrawVert v[4] = {
    { UNPACK3(*p1), 0, 0 }, { UNPACK3(*p2), 0, 1 },
    { UNPACK3(*p3), 1, 1 }, { UNPACK3(*p4), 1, 0 },
  };
  Draw_Enqueue(v, 4, GL_QUADS);
}

void Draw_Rect (float x1, float y1, float xs, float ys) {
  float x2 = x1 + xs;
  float y2 = y1 + ys;
  DrawVert v[4] = {
    { x1, y1, 0, 0, 0 }, { x1, y2, 0, 0, 1 },
    { x2, y2, 0, 1, 1 }, { x2, y1, 0, 1, 0 },
  };
  Draw_Enqueue(v, 4, GL_QUADS);
}

/* NOTE : GL_LINE_SMOOTH / GL_POINT_SMOOTH are compatibility-only and were
 * removed in the core-profile migration (stage 5). The setters remain for
 * API compatibility but no longer touch GL state. */
static bool s_smoothLines = false;
static bool s_smoothPoints = false;

void Draw_SmoothLines (bool enabled) {
  s_smoothLines = enabled;
}

void Draw_SmoothPoints (bool enabled) {
  s_smoothPoints = enabled;
}

inline static Vec3f Spherical (float r, float yaw, float pitch) {
  return Vec3f_Create(
    r * Sin(pitch) * Cos(yaw),
    r * Cos(pitch),
    r * Sin(pitch) * Sin(yaw));
}

/* Draw_Sphere — rebuilt with the VBO path. Each cap emits TRIANGLES and the
 * middle band QUADS, matching the old immediate-mode expansion exactly. */
void Draw_Sphere (Vec3f const* p, float r) {
  const size_t res = 7;
  const float fRes = float(res);

  /* First Row */ {
    DrawVert v[res * 3];
    int n = 0;
    float lastTheta = float(res - 1) / fRes * Tau;
    float phi = 1.0f / fRes * Pi;
    Vec3f tc = Vec3f_Add(*p, Spherical(r, 0, 0));
    for (size_t iTheta = 0; iTheta < res; iTheta++) {
      float theta = float(iTheta) / fRes * Tau;
      Vec3f br = Vec3f_Add(*p, Spherical(r, lastTheta, phi));
      Vec3f bl = Vec3f_Add(*p, Spherical(r, theta, phi));
      v[n++] = DrawVert{ UNPACK3(br), 0, 0 };
      v[n++] = DrawVert{ UNPACK3(tc), 0, 0 };
      v[n++] = DrawVert{ UNPACK3(bl), 0, 0 };
      lastTheta = theta;
    }
    Draw_Enqueue(v, n, GL_TRIANGLES);
  }

  /* Middle Rows */ {
    DrawVert v[res * res * 8];
    int n = 0;
    float lastPhi = 1.0f / fRes * Pi;
    float lastTheta = float(res - 1) / fRes * Tau;

    for (size_t iPhi = 2; iPhi < res; iPhi++) {
      float phi = float(iPhi) / fRes * Pi;
      for (size_t iTheta = 0; iTheta < res; iTheta++) {
        float theta = float(iTheta) / fRes * Tau;
        Vec3f br = Vec3f_Add(*p, Spherical(r, lastTheta, phi));
        Vec3f tr = Vec3f_Add(*p, Spherical(r, lastTheta, lastPhi));
        Vec3f tl = Vec3f_Add(*p, Spherical(r, theta, lastPhi));
        Vec3f bl = Vec3f_Add(*p, Spherical(r, theta, phi));
        v[n++] = DrawVert{ UNPACK3(br), 0, 0 };
        v[n++] = DrawVert{ UNPACK3(tr), 0, 0 };
        v[n++] = DrawVert{ UNPACK3(tl), 0, 0 };
        v[n++] = DrawVert{ UNPACK3(bl), 0, 0 };
        lastTheta = theta;
      }
      lastPhi = phi;
    }
    Draw_Enqueue(v, n, GL_QUADS);
  }

  /* Bottom Row */ {
    DrawVert v[res * 3];
    int n = 0;
    float lastTheta = float(res - 1) / fRes * Tau;
    float phi = float(res - 1) / fRes * Pi;
    Vec3f bc = Vec3f_Add(*p, Spherical(r, 0, Pi));

    for (size_t iTheta = 0; iTheta < res; iTheta++) {
      float theta = float(iTheta) / fRes * Tau;
      Vec3f tr = Vec3f_Add(*p, Spherical(r, lastTheta, phi));
      Vec3f tl = Vec3f_Add(*p, Spherical(r, theta, phi));
      v[n++] = DrawVert{ UNPACK3(tr), 0, 0 };
      v[n++] = DrawVert{ UNPACK3(tl), 0, 0 };
      v[n++] = DrawVert{ UNPACK3(bc), 0, 0 };
      lastTheta = theta;
    }
    Draw_Enqueue(v, n, GL_TRIANGLES);
  }
}

void Draw_Tri (Vec2f const* v1, Vec2f const* v2, Vec2f const* v3) {
  DrawVert v[3] = {
    { UNPACK2(*v1), 0, 0 }, { UNPACK2(*v2), 0, 1 }, { UNPACK2(*v3), 1, 1 },
  };
  Draw_Enqueue(v, 3, GL_TRIANGLES);
}

void Draw_Tri3 (Vec3f const* v1, Vec3f const* v2, Vec3f const* v3) {
  DrawVert v[3] = {
    { UNPACK3(*v1), 0, 0 }, { UNPACK3(*v2), 0, 1 }, { UNPACK3(*v3), 1, 1 },
  };
  Draw_Enqueue(v, 3, GL_TRIANGLES);
}
