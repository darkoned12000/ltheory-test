#include fragment
#include math
#include noise

layout(location = 0) out vec4 fragColor;

uniform vec3  origin;
uniform vec3  du;
uniform vec3  dv;
uniform int   octaves;
uniform float seed;
uniform float smoothness;

/* Scale & Shape Uniforms for Variable Size Asteroids */
uniform float noiseFreq;   /* Detail frequency scaled to object size */
uniform vec3  aspect;      /* Anisotropic stretch */
uniform float craterDepth; /* Depth scaling for impact depressions */

void main() {
  vec3 p = origin + du * uv.x + dv * uv.y;

  // Validate aspect scale to prevent division by zero or negative space inversion
  vec3 safeAspect = max(vec3(0.1), aspect);
  vec3 q = p * safeAspect;

  float safeFreq = max(1e-4, noiseFreq);
  int safeOctaves = clamp(octaves, 1, 8);

  // Evaluate multi-octave cellular noise
  float n = fCellNoise(safeFreq * q, seed, safeOctaves, smoothness);

  // Implicit surface distance with variable crater depth modulation
  float baseRadius = 1.0;
  float surfaceOffset = mix(0.05, 1.0, n) * craterDepth;
  float rawDistance = length(q) - (baseRadius - surfaceOffset);

  // Correct metric scaling to prevent raymarching overshots and mesh tearing
  float maxScale = max(safeAspect.x, max(safeAspect.y, safeAspect.z));
  float d = rawDistance / maxScale;

  if (isnan(d)) {
    d = 0.0;
  }

  // fragColor.x: True SDF distance
  // fragColor.y: Cell fracture seam weight (enables procedural mesh fragmentation)
  // fragColor.z: Unused (reserved for damage masks)
  // fragColor.w: Solid alpha
  fragColor = vec4(d, n, 0.0, 1.0);
}
