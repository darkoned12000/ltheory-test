#include "Array.h"
#include "LineSegment.h"
#include "Ray.h"

void LineSegment_ToRay (LineSegment const* self, Ray* out) {
  out->p = self->p0;
  out->dir = Vec3f_Sub(self->p1, self->p0);
  out->tMin = 0.0f;
  out->tMax = 1.0f;
}

void LineSegment_FromRay (Ray const* ray, LineSegment* out) {
  Ray_ToLineSegment(ray, out);
}

cstr LineSegment_ToString (LineSegment* self) {
  static char buffer[512];
  snprintf(buffer, (size_t) Array_GetSize(buffer),
    "p0:(%.4f, %.4f, %.4f) p1:(%.4f, %.4f, %.4f)",
    self->p0.x, self->p0.y, self->p0.z,
    self->p1.x, self->p1.y, self->p1.z
  );
  return buffer;
}
