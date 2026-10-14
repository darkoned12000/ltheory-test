#include fragment
#include color
#include math
#include noise
#include texcube

layout(location = 0) out vec4 fragColor;
uniform vec3 color;
uniform float seed;
uniform float starGlow;   /* Central Star brightness, baked into the cube.
                             * Was hardcoded 8.0/4.0 = a 12x peak, i.e. clipped to
                             * solid white across a broad patch of the sky cube
                             * (measured: the +X face ran p99 254 while every
                             * other face sat near 80). Because it is baked at
                             * GENERATION time, no runtime toggle could remove it.
                             * 0 = no baked glow (the skybox star alone),
                             * 0.35 = a gentle brightening that does not clip,
                             * 1.0+ = the old blown-out look. */

const vec3 c2 = vec3(0.4583, 0.2238, 0.0928);

float bgDensity(vec3 p) {
  return 0.5 + 0.5 * fSmoothNoise(p * 4.0 + seed, 4, 2.0);
}

vec4 generate(vec3 dir) {
  vec3 c = vec3(0.0);
  float dense = bgDensity(dir);

  /* Central Star. */ {
    /* Dots between normalized Vec3fs may still be > 1 due to fp precision! */
    float d = max(0.0, 1.0 - dot(dir, starDir));
    float dd = 0.0;
    // Shape preserved from the old 8.0 / 4.0 pair (the wide term is half the
    // tight one); only the amplitude is now a knob.
    dd += starGlow * exp(-sqrt(4096.0 * d));
    dd += starGlow * 0.5 * exp(-sqrt(sqrt(1024.0 * d)));
    c += dd * color;
  }

  float d1 = 2.0 * frCellNoise(dir, seed + 1.0, 3, 2.0) - 1.0;
  float d2 = 2.0 * frCellNoise(dir, seed + 2.0, 3, 2.0) - 1.0;
  float d3 = 2.0 * frCellNoise(dir, seed + 3.0, 3, 2.0) - 1.0;
  dir += 0.1 * vec3(d1, d2, d3);
  float k = frCellNoise(dir, seed, 4, 2.0);
  float k2 = frCellNoise(2.0 * dir, seed + 4.0, 4, 2.0);
  k = sqrt(max(0.0, k * k2));

  c += k * exp(-(k * c2));
  float kd = abs((k - k2) - 0.05);
  c *= 2.0 - exp(-4.0 * kd * c2);

  return vec4(max(c, vec3(0.0)), clamp(avg(c), 0.0, 1.0));
}

void main() {
  vec3 dir = cubeMapDir(uv);
  vec4 c = generate(dir);

  if (isnan(c.r) || isnan(c.g) || isnan(c.b) || isnan(c.a)) {
    c = vec4(0.0, 0.0, 0.0, 1.0);
  }
  fragColor = clamp(c, vec4(0.0), vec4(10.0));
}
