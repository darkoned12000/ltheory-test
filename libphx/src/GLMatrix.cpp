#include "GLMatrix.h"
#include "Matrix.h"
#include "PhxMath.h"
#include "Vec3.h"

/* CPU-side matrix stacks (P and WV) replacing the fixed-function matrix
 * stack, which was removed in the core-profile migration (stage 5).
 *
 * The API intentionally mirrors the old GL semantics:
 *   - Load replaces the top of the current stack.
 *   - Mult / Translate / Rotate / Scale / LookAt / Perspective POST-multiply
 *     onto the top (top = top * new), exactly like the old glMultMatrix /
 *     glTranslate / ... calls.
 *   - Rotate takes degrees, matching glRotated.
 *   - Get returns a clone of the current stack top.
 *
 * NOTE : Nothing in the renderer consumes these matrices anymore — shaders
 * read mView/mProj autovars pushed by the camera code. The stacks exist to
 * keep the Lua-facing API (CoordTest/BSPTest dev apps) alive and honest. */

#define GLMATRIX_MAX_DEPTH 16

static Matrix* stackP[GLMATRIX_MAX_DEPTH];
static Matrix* stackWV[GLMATRIX_MAX_DEPTH];
static int depthP = -1;
static int depthWV = -1;
static bool modeP = true; /* true = projection stack, false = WV stack */

static Matrix** curStack () { return modeP ? stackP : stackWV; }
static int* curDepth () { return modeP ? &depthP : &depthWV; }

/* Like GL, each stack implicitly contains a single identity matrix before
 * the first Push. */
static void ensureSeeded () {
  Matrix** s = curStack();
  int* d = curDepth();
  if (*d >= 0) return;
  s[0] = Matrix_Identity();
  *d = 0;
}

void GLMatrix_Clear () {
  ensureSeeded();
  int* d = curDepth();
  Matrix** s = curStack();
  Matrix_Free(s[*d]);
  s[*d] = Matrix_Identity();
}

void GLMatrix_Load (Matrix* matrix) {
  ensureSeeded();
  int* d = curDepth();
  Matrix** s = curStack();
  Matrix_Free(s[*d]);
  s[*d] = Matrix_Clone(matrix);
}

void GLMatrix_LookAt (Vec3d const* eye, Vec3d const* at, Vec3d const* up) {
  Vec3f e = Vec3f_Create((float)eye->x, (float)eye->y, (float)eye->z);
  Vec3f a = Vec3f_Create((float)at->x, (float)at->y, (float)at->z);
  Vec3f u = Vec3f_Create((float)up->x, (float)up->y, (float)up->z);

  /* Same basis construction as the old implementation: right-handed
   * look-at with a -Z forward flip. */
  Vec3f z = Vec3f_Normalize(Vec3f_Sub(a, e));
  Vec3f x = Vec3f_Normalize(Vec3f_Cross(z, Vec3f_Normalize(u)));
  Vec3f y = Vec3f_Cross(x, z);

  /* Basis vectors as matrix rows (matching the old glMultMatrixd data);
   * composition order replicates the old basis-then-translate sequence. */
  Matrix* r = Matrix_Identity();
  float* m = (float*)r;
  m[0] = x.x; m[1] = x.y; m[2] = x.z;
  m[4] = y.x; m[5] = y.y; m[6] = y.z;
  m[8] = -z.x; m[9] = -z.y; m[10] = -z.z;

  Matrix* t = Matrix_Translation(-e.x, -e.y, -e.z);
  Matrix* view = Matrix_Product(r, t);
  Matrix_Free(r);
  Matrix_Free(t);

  GLMatrix_Mult(view);
  Matrix_Free(view);
}

void GLMatrix_ModeP () {
  modeP = true;
}

void GLMatrix_ModeWV () {
  modeP = false;
}

void GLMatrix_Mult (Matrix* matrix) {
  ensureSeeded();
  int* d = curDepth();
  Matrix** s = curStack();
  Matrix* product = Matrix_Product(s[*d], matrix);
  Matrix_Free(s[*d]);
  s[*d] = product;
}

void GLMatrix_Perspective (double fovy, double aspect, double z0, double z1) {
  double rads = Pi * fovy / 360.0;
  double cot = 1.0 / Tan(rads);
  double dz = z1 - z0;
  double nf = -2.0 * (z0 * z1) / dz;

  Matrix* p = Matrix_Identity();
  float* m = (float*)p;
  /* Engine matrices are row-major storage of the standard column-vector
   * matrix, so nf lands at row 2 / col 3 and -1 at row 3 / col 2 — the
   * opposite indices from GL's column-major initializer in the old code. */
  m[0] = (float)(cot / aspect);
  m[5] = (float)cot;
  m[10] = (float)(-(z0 + z1) / dz);
  m[11] = (float)nf;
  m[14] = -1.0f;

  GLMatrix_Mult(p);
  Matrix_Free(p);
}

void GLMatrix_Pop () {
  ensureSeeded();
  int* d = curDepth();
  Matrix** s = curStack();
  if (*d == 0)
    Fatal("GLMatrix_Pop: stack underflow (cannot pop the base matrix)");
  Matrix_Free(s[*d]);
  s[*d] = nullptr;
  --(*d);
}

void GLMatrix_Push () {
  ensureSeeded();
  int* d = curDepth();
  Matrix** s = curStack();
  if (*d + 1 >= GLMATRIX_MAX_DEPTH)
    Fatal("GLMatrix_Push: Maximum matrix stack depth exceeded");
  ++(*d);
  s[*d] = (*d > 0) ? Matrix_Clone(s[*d - 1]) : Matrix_Identity();
}

void GLMatrix_PushClear () {
  GLMatrix_Push();
  GLMatrix_Clear();
}

Matrix* GLMatrix_Get () {
  ensureSeeded();
  int* d = curDepth();
  Matrix** s = curStack();
  return Matrix_Clone(s[*d]);
}

void GLMatrix_RotateX (double angle) {
  Matrix* r = Matrix_RotationX((float)(angle * Pi / 180.0));
  GLMatrix_Mult(r);
  Matrix_Free(r);
}

void GLMatrix_RotateY (double angle) {
  Matrix* r = Matrix_RotationY((float)(angle * Pi / 180.0));
  GLMatrix_Mult(r);
  Matrix_Free(r);
}

void GLMatrix_RotateZ (double angle) {
  Matrix* r = Matrix_RotationZ((float)(angle * Pi / 180.0));
  GLMatrix_Mult(r);
  Matrix_Free(r);
}

void GLMatrix_Scale (double x, double y, double z) {
  Matrix* s = Matrix_Scaling((float)x, (float)y, (float)z);
  GLMatrix_Mult(s);
  Matrix_Free(s);
}

void GLMatrix_Translate (double x, double y, double z) {
  Matrix* t = Matrix_Translation((float)x, (float)y, (float)z);
  GLMatrix_Mult(t);
  Matrix_Free(t);
}
