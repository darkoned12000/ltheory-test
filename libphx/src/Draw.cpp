#include "Draw.h"
#include "Metric.h"
#include "OpenGL.h"
#include "Vec4.h"

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

static void Draw_Init () {
  if (s_init) return;
  s_init = true;
  GLCALL(glGenBuffers(1, &s_vbo));
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
static void Draw_Flush (GLenum mode) {
  if (s_count == 0) return;

  Draw_Bind();
  GLCALL(glBufferData(GL_ARRAY_BUFFER, (GLsizeiptr)(s_count * (int)sizeof(DrawVert)), s_verts, GL_DYNAMIC_DRAW));

  switch (mode) {
    case GL_LINES:
    case GL_POINTS:
    case GL_TRIANGLES:
      GLCALL(glDrawArrays(mode, 0, s_count));
      break;

    case GL_QUADS: {
      /* Each quad (4 verts) -> 2 triangles (6 indices). */
      int quads = s_count / 4;
      for (int q = 0; q < quads; ++q) {
        int b = q * 4;
        GLCALL(glDrawArrays(GL_TRIANGLES, b,      3));
        GLCALL(glDrawArrays(GL_TRIANGLES, b + 1,  3));
      }
      break;
    }

    case GL_POLYGON: {
      /* Triangle fan: (0, i, i+1) for i in [1, count-2].
       * POLYGON is only used by debug overlays, so re-uploading one
       * triangle at a time is fine. */
      DrawVert fan[3];
      for (int i = 1; i < s_count - 1; ++i) {
        fan[0] = s_verts[0];
        fan[1] = s_verts[i];
        fan[2] = s_verts[i + 1];
        GLCALL(glBufferData(GL_ARRAY_BUFFER, sizeof(fan), fan, GL_DYNAMIC_DRAW));
        GLCALL(glDrawArrays(GL_TRIANGLES, 0, 3));
      }
      break;
    }
  }

  Draw_Unbind();
  s_count = 0;
}

/* Begin/End helpers — accumulate then flush. */
static inline void Draw_Begin () { s_count = 0; }

void Draw_PushAlpha (float a) {
  if (alphaIndex + 1 >= MAX_STACK_DEPTH)
      Fatal("Draw_PushAlpha: Maximum alpha stack depth exceeded");

  float prevAlpha = alphaIndex >= 0 ? alphaStack[alphaIndex] : 1;
  float alpha = a * prevAlpha;
  alphaStack[++alphaIndex] = alpha;
  GLCALL(glColor4f(color.x, color.y, color.z, color.w * alpha));
}

void Draw_PopAlpha () {
  if (alphaIndex < 0)
      Fatal("Draw_PopAlpha Attempting to pop an empty alpha stack");

  alphaIndex--;
  float alpha = alphaIndex >= 0 ? alphaStack[alphaIndex] : 1;
  GLCALL(glColor4f(color.x, color.y, color.z, color.w * alpha));
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
  glColor4f(1, 0.25f, 0.25f, _alpha);
  Draw_Begin();
  Draw_Push(UNPACK3(*pos), 0, 0);
  Draw_Push(UNPACK3(left), 0, 0);
  Draw_Push(UNPACK3(*pos), 0, 0);
  Draw_Push(UNPACK3(up), 0, 0);
  Draw_Push(UNPACK3(*pos), 0, 0);
  Draw_Push(UNPACK3(forward), 0, 0);
  Draw_Flush(GL_LINES);

  glColor4f(1, 1, 1, _alpha);
  Draw_Begin();
  Draw_Push(UNPACK3(*pos), 0, 0);
  Draw_Flush(GL_POINTS);
}

void Draw_Border (float s, float x, float y, float w, float h) {
  Draw_Rect(x, y, w, s);
  Draw_Rect(x, y + h - s, w, s);
  Draw_Rect(x, y + s, s, h - 2*s);
  Draw_Rect(x + w - s, y + s, s, h - 2*s);
}

void Draw_Box3 (Box3f const* self) {
  Metric_AddDrawImm(6, 12, 24);
  Draw_Begin();
  /* Left. */
  Draw_Push(self->lower.x, self->lower.y, self->lower.z, 0, 0);
  Draw_Push(self->lower.x, self->lower.y, self->upper.z, 0, 0);
  Draw_Push(self->lower.x, self->upper.y, self->upper.z, 0, 0);
  Draw_Push(self->lower.x, self->upper.y, self->lower.z, 0, 0);
  /* Right. */
  Draw_Push(self->upper.x, self->lower.y, self->lower.z, 0, 0);
  Draw_Push(self->upper.x, self->upper.y, self->lower.z, 0, 0);
  Draw_Push(self->upper.x, self->upper.y, self->upper.z, 0, 0);
  Draw_Push(self->upper.x, self->lower.y, self->upper.z, 0, 0);
  /* Front. */
  Draw_Push(self->lower.x, self->lower.y, self->upper.z, 0, 0);
  Draw_Push(self->upper.x, self->lower.y, self->upper.z, 0, 0);
  Draw_Push(self->upper.x, self->upper.y, self->upper.z, 0, 0);
  Draw_Push(self->lower.x, self->upper.y, self->upper.z, 0, 0);
  /* Back. */
  Draw_Push(self->lower.x, self->lower.y, self->lower.z, 0, 0);
  Draw_Push(self->lower.x, self->upper.y, self->lower.z, 0, 0);
  Draw_Push(self->upper.x, self->upper.y, self->lower.z, 0, 0);
  Draw_Push(self->upper.x, self->lower.y, self->lower.z, 0, 0);
  /* Top. */
  Draw_Push(self->lower.x, self->upper.y, self->lower.z, 0, 0);
  Draw_Push(self->lower.x, self->upper.y, self->upper.z, 0, 0);
  Draw_Push(self->upper.x, self->upper.y, self->upper.z, 0, 0);
  Draw_Push(self->upper.x, self->upper.y, self->lower.z, 0, 0);
  /* Bottom. */
  Draw_Push(self->lower.x, self->lower.y, self->lower.z, 0, 0);
  Draw_Push(self->upper.x, self->lower.y, self->lower.z, 0, 0);
  Draw_Push(self->upper.x, self->lower.y, self->upper.z, 0, 0);
  Draw_Push(self->lower.x, self->lower.y, self->upper.z, 0, 0);
  Draw_Flush(GL_QUADS);
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
  GLCALL(glColor4f(r, g, b, a * alpha))
}

void Draw_Flush () {
  Metric_Inc(Metric_Flush);
  GLCALL(glFinish())
}

void Draw_Line (float x1, float y1, float x2, float y2) {
  Draw_Begin();
  Draw_Push(x1, y1, 0, 0, 0);
  Draw_Push(x2, y2, 0, 0, 0);
  Draw_Flush(GL_LINES);
}

void Draw_Line3 (Vec3f const* p1, Vec3f const* p2) {
  Draw_Begin();
  Draw_Push(UNPACK3(*p1), 0, 0);
  Draw_Push(UNPACK3(*p2), 0, 0);
  Draw_Flush(GL_LINES);
}

void Draw_LineWidth (float width) {
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

  Metric_AddDrawImm(1, 2, 4);
  Draw_Begin();
  Draw_Push(UNPACK3(p0), 0, 0);
  Draw_Push(UNPACK3(p1), 0, 0);
  Draw_Push(UNPACK3(p2), 0, 0);
  Draw_Push(UNPACK3(p3), 0, 0);
  Draw_Flush(GL_QUADS);
}

void Draw_Point (float x, float y) {
  Draw_Begin();
  Draw_Push(x, y, 0, 0, 0);
  Draw_Flush(GL_POINTS);
}

void Draw_Point3 (float x, float y, float z) {
  Draw_Begin();
  Draw_Push(x, y, z, 0, 0);
  Draw_Flush(GL_POINTS);
}

void Draw_PointSize (float size) {
  GLCALL(glPointSize(size))
}

void Draw_Poly (Vec2f const* points, int count) {
  Metric_AddDrawImm(1, count - 2, count);
  Draw_Begin();
  for (int i = 0; i < count; ++i)
    Draw_Push(UNPACK2(points[i]), 0, 0);
  Draw_Flush(GL_POLYGON);
}

void Draw_Poly3 (Vec3f const* points, int count) {
  Metric_AddDrawImm(1, count - 2, count);
  Draw_Begin();
  for (int i = 0; i < count; ++i)
    Draw_Push(UNPACK3(points[i]), 0, 0);
  Draw_Flush(GL_POLYGON);
}

void Draw_Quad (Vec2f const* p1, Vec2f const* p2, Vec2f const* p3, Vec2f const* p4) {
  Metric_AddDrawImm(1, 2, 4);
  Draw_Begin();
  Draw_Push(UNPACK2(*p1), 0, 0);
  Draw_Push(UNPACK2(*p2), 0, 1);
  Draw_Push(UNPACK2(*p3), 1, 1);
  Draw_Push(UNPACK2(*p4), 1, 0);
  Draw_Flush(GL_QUADS);
}

void Draw_Quad3 (Vec3f const* p1, Vec3f const* p2, Vec3f const* p3, Vec3f const* p4) {
  Metric_AddDrawImm(1, 2, 4);
  Draw_Begin();
  Draw_Push(UNPACK3(*p1), 0, 0);
  Draw_Push(UNPACK3(*p2), 0, 1);
  Draw_Push(UNPACK3(*p3), 1, 1);
  Draw_Push(UNPACK3(*p4), 1, 0);
  Draw_Flush(GL_QUADS);
}

void Draw_Rect (float x1, float y1, float xs, float ys) {
  float x2 = x1 + xs;
  float y2 = y1 + ys;
  Metric_AddDrawImm(1, 2, 4);
  Draw_Begin();
  Draw_Push(x1, y1, 0, 0, 0);
  Draw_Push(x1, y2, 0, 0, 1);
  Draw_Push(x2, y2, 0, 1, 1);
  Draw_Push(x2, y1, 0, 1, 0);
  Draw_Flush(GL_QUADS);
}

void Draw_SmoothLines (bool enabled) {
  if (enabled) {
    GLCALL(glEnable(GL_LINE_SMOOTH))
    GLCALL(glHint(GL_LINE_SMOOTH_HINT, GL_NICEST))
  } else {
    GLCALL(glDisable(GL_LINE_SMOOTH))
    GLCALL(glHint(GL_LINE_SMOOTH_HINT, GL_FASTEST))
  }
}

void Draw_SmoothPoints (bool enabled) {
  if (enabled) {
    GLCALL(glEnable(GL_POINT_SMOOTH))
    GLCALL(glHint(GL_POINT_SMOOTH_HINT, GL_NICEST))
  } else {
    GLCALL(glDisable(GL_POINT_SMOOTH))
    GLCALL(glHint(GL_POINT_SMOOTH_HINT, GL_FASTEST))
  }
}

inline static Vec3f Spherical (float r, float yaw, float pitch) {
  return Vec3f_Create(
    r * Sin(pitch) * Cos(yaw),
    r * Cos(pitch),
    r * Sin(pitch) * Sin(yaw));
}

/* Draw_Sphere — rebuilt with the VBO path. Each row emits its own primitive
 * (TRIANGLES for caps, QUADS for the middle band), matching the old
 * immediate-mode expansion exactly. */
void Draw_Sphere (Vec3f const* p, float r) {
  const size_t res = 7;
  const float fRes = float(res);

  /* First Row */ {
    Metric_AddDrawImm(res, res, res * 3);
    float lastTheta = float(res - 1) / fRes * Tau;
    float phi = 1.0f / fRes * Pi;
    Vec3f tc = Vec3f_Add(*p, Spherical(r, 0, 0));
    Draw_Begin();
    for (size_t iTheta = 0; iTheta < res; iTheta++) {
      float theta = float(iTheta) / fRes * Tau;
      Vec3f br = Vec3f_Add(*p, Spherical(r, lastTheta, phi));
      Vec3f bl = Vec3f_Add(*p, Spherical(r, theta, phi));
      Draw_Push(UNPACK3(br), 0, 0);
      Draw_Push(UNPACK3(tc), 0, 0);
      Draw_Push(UNPACK3(bl), 0, 0);
      lastTheta = theta;
    }
    Draw_Flush(GL_TRIANGLES);
  }

  /* Middle Rows */ {
    Metric_AddDrawImm(res - 2, 2 * (res - 2), 4 * (res - 2));
    float lastPhi = 1.0f / fRes * Pi;
    float lastTheta = float(res - 1) / fRes * Tau;

    for (size_t iPhi = 2; iPhi < res; iPhi++) {
      float phi = float(iPhi) / fRes * Pi;
      Draw_Begin();
      for (size_t iTheta = 0; iTheta < res; iTheta++) {
        float theta = float(iTheta) / fRes * Tau;
        Vec3f br = Vec3f_Add(*p, Spherical(r, lastTheta, phi));
        Vec3f tr = Vec3f_Add(*p, Spherical(r, lastTheta, lastPhi));
        Vec3f tl = Vec3f_Add(*p, Spherical(r, theta, lastPhi));
        Vec3f bl = Vec3f_Add(*p, Spherical(r, theta, phi));
        Draw_Push(UNPACK3(br), 0, 0);
        Draw_Push(UNPACK3(tr), 0, 0);
        Draw_Push(UNPACK3(tl), 0, 0);
        Draw_Push(UNPACK3(bl), 0, 0);
        lastTheta = theta;
      }
      Draw_Flush(GL_QUADS);
      lastPhi = phi;
    }
  }

  /* Bottom Row */ {
    Metric_AddDrawImm(res, res, res * 3);
    float lastTheta = float(res - 1) / fRes * Tau;
    float phi = float(res - 1) / fRes * Pi;
    Vec3f bc = Vec3f_Add(*p, Spherical(r, 0, Pi));

    Draw_Begin();
    for (size_t iTheta = 0; iTheta < res; iTheta++) {
      float theta = float(iTheta) / fRes * Tau;
      Vec3f tr = Vec3f_Add(*p, Spherical(r, lastTheta, phi));
      Vec3f tl = Vec3f_Add(*p, Spherical(r, theta, phi));
      Draw_Push(UNPACK3(tr), 0, 0);
      Draw_Push(UNPACK3(tl), 0, 0);
      Draw_Push(UNPACK3(bc), 0, 0);
      lastTheta = theta;
    }
    Draw_Flush(GL_TRIANGLES);
  }
}

void Draw_Tri (Vec2f const* v1, Vec2f const* v2, Vec2f const* v3) {
  Metric_AddDrawImm(1, 1, 3);
  Draw_Begin();
  Draw_Push(UNPACK2(*v1), 0, 0);
  Draw_Push(UNPACK2(*v2), 0, 1);
  Draw_Push(UNPACK2(*v3), 1, 1);
  Draw_Flush(GL_TRIANGLES);
}

void Draw_Tri3 (Vec3f const* v1, Vec3f const* v2, Vec3f const* v3) {
  Metric_AddDrawImm(1, 1, 3);
  Draw_Begin();
  Draw_Push(UNPACK3(*v1), 0, 0);
  Draw_Push(UNPACK3(*v2), 0, 1);
  Draw_Push(UNPACK3(*v3), 1, 1);
  Draw_Flush(GL_TRIANGLES);
}
