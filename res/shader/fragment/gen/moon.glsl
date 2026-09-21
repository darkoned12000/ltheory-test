/* -- Moon / barren body generation ------------------------------------------
   Height field for moons. Deliberately a DIFFERENT structure from gen/planet:
   a ridged multifractal base (sharp crests) plus cellular crater bowls/rims,
   instead of the planet's smooth sine-bandpass terrain. The material
   (material/planet.glsl) maps height -> palette, so a different height
   structure is what makes a moon read as its own body rather than a recoloured
   planet.

   Output matches gen/planet: RGBA = (height, aux, clouds, 0). Clouds are 0.

   Uniforms mirror gen/planet (coef is unused here but kept so the shared
   uniform set stays valid for the offscreen generator).
---------------------------------------------------------------------------- */

#include fragment
#include math
#include noise
#include texcube

layout(location = 0) out vec4 fragColor;

uniform float seed;
uniform float freq;
uniform float power;
uniform vec4  coef;

// Craters: a cell field gives pit centres; a bowl + raised-rim profile carves
// them. Multi-octave so small craters pepper the larger ones.
float genCraters (vec3 p) {
  float c = 0.0;
  float amp = 1.0;
  float f = max(0.5, freq) * 0.5;
  for (int i = 0; i < 4; ++i) {
    float d = cellNoise(p * f + vec3(seed), seed + float(i) * 11.0);
    float bowl = smoothstep(0.0, 0.30, d);
    float rim  = 1.0 - smoothstep(0.30, 0.46, d);
    c += amp * (rim * 0.55 - (1.0 - bowl) * 0.5);
    amp *= 0.5;
    f *= 2.3;
  }
  return c;
}

// Ridged multifractal base: sharp mountain crests.
float genRidged (vec3 p) {
  float acc = 0.0;
  float w = 1.0;
  float f = max(0.5, freq);
  for (int i = 0; i < 6; ++i) {
    float n = 1.0 - abs(2.0 * cellNoise(p * f, seed + float(i) * 7.0) - 1.0);
    acc += w * n * n;
    w *= 0.5;
    f *= 2.0;
  }
  return clamp(acc, 0.0, 1.0);
}

void main () {
  vec3 p = cubeMapDir(uv);
  float base = genRidged(p);
  float cr   = genCraters(p);
  // coef.x steers crater strength. It MUST be used: an unused uniform is
  // optimized out of the program, and setting a missing uniform aborts the
  // engine (Shader_GetVariable). Keeps the shared uniform set valid.
  float crAmt = clamp(coef.x * 6.0, 0.1, 0.8);
  float h = clamp(base + crAmt * cr, 0.0, 1.0);
  h = gain(pow(h, max(0.05, power)), 4.0);

  vec4 c = vec4(h, base, 0.0, 0.0);
  if (isnan(c.r) || isnan(c.g) || isnan(c.b) || isnan(c.a)) {
    c = vec4(0.0);
  }
  fragColor = clamp(c, vec4(0.0), vec4(10.0));
}
