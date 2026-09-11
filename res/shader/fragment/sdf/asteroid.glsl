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
uniform vec3  aspect;      /* Anisotropic stretch (e.g., vec3(1.4, 0.8, 1.0) for potato shape) */
uniform float craterDepth; /* Depth scaling for impact depressions */

void main() {
  vec3 p = origin + du * uv.x + dv * uv.y;

  // Apply aspect ratio distortion for non-spherical asteroids
  vec3 q = p * max(vec3(0.1), aspect);

  // Evaluate multi-octave cellular noise scaled by object size
  float n = fCellNoise(noiseFreq * q, seed, octaves, smoothness);

  // Implicit surface distance with variable crater depth modulation
  float baseRadius = 1.0;
  float surfaceOffset = mix(0.05, 1.0, n) * craterDepth;
  float d = length(q) - (baseRadius - surfaceOffset);

  fragColor.x = d;
}
