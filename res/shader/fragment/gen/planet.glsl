#include fragment
#include math
#include noise
#include texcube

layout(location = 0) out vec4 fragColor;

uniform float seed;
uniform float freq;
uniform float power;
uniform vec4 coef;
uniform float mountain;   // ridge amplitude (0 = featureless, 1 = strong ranges)
uniform float crater;     // impact-crater amplitude (0 = none)

float genClouds(vec3 p) {
  p += 0.5 * vec3(
    fCellNoise(p, seed + 1.0, 4, 1.3),
    fCellNoise(p, seed + 5.0, 4, 1.3),
    fCellNoise(p, seed + 8.0, 4, 1.3));
  return 0.5 + 0.5 * sin(8.0 * frCellNoise(p, seed + 6.0, 6, 1.4));
}

float genColor(vec3 p) {
  // Pre-scaled initial vector
  vec4 z = vec4(p * 0.25 + 0.75, 0.3);
  float a = 0.0, l = 0.0, w = 1.0;

  for (int i = 0; i < 12; ++i) {
    float m = max(dot(z, z), 1e-5);
    z = abs(z) / m - vec4(0.4, 0.5, 0.6, 0.4);
    z += 0.1 * log(max(vec4(1e-6), 1.0e-10 + noise4(float(i) + seed + 58.329)));
    z *= 1.0 + 0.25 * noise(float(i) + seed * 5.0 + 12.0);
    z = z.yzwx;
    m = coef.x*z.x*z.x + coef.y*z.y*z.y + coef.z*z.z*z.z + coef.w*z.w*z.w;
    a += w * exp(-m);
    w *= 0.85;
    l = m;
  }
  return 0.5 + 0.5 * sin(4.0 * a);
}

// Ridged multifractal: sharp crests, for mountain ranges (unlike the smooth
// sine-bandpass base terrain). Amplitude is scaled by `mountain` per type.
float genRidge (vec3 p) {
  float acc = 0.0, w = 1.0, f = max(1.0, freq);
  for (int i = 0; i < 6; ++i) {
    float n = 1.0 - abs(2.0 * cellNoise(p * f, seed + 3.7 + float(i) * 13.0) - 1.0);
    acc += w * n * n * n;   // sharper crests => more pronounced ranges
    w *= 0.5;
    f *= 2.07;
  }
  return clamp(acc, 0.0, 1.0);
}

// Impact craters / basins: a cell field gives pit centres; a bowl + raised rim
// profile carves them (subtler that gen/moon's — planets have weather).
float genCraters (vec3 p) {
  float c = 0.0, amp = 1.0, f = max(1.0, freq) * 1.15;
  for (int i = 0; i < 4; ++i) {
    float d = cellNoise(p * f + vec3(seed), seed + 5.1 + float(i) * 11.0);
    float bowl = smoothstep(0.0, 0.35, d);          // 0 at the pit centre
    float rim  = 1.0 - smoothstep(0.35, 0.5, d);    // raised ring at the edge
    c += amp * (rim * 0.35 - (1.0 - bowl) * 0.9);   // deep bowl + rim
    amp *= 0.5;
    f *= 2.3;
  }
  return c;
}

float genHeight(vec3 p) {
  // Pre-scaled initial vector
  vec4 z = vec4(p * 0.25 + 0.75, 0.3);
  float a = 0.0, l = 0.0, w = 1.0;

  for (int i = 0; i < 16; ++i) {
    float m = max(dot(z, z), 1e-5);
    z = abs(z) / m - vec4(0.4, 0.5, 0.6, 0.3);
    z += 0.1 * log(max(vec4(1e-6), 1.0e-10 + noise4(float(i) + seed)));
    z *= 1.0 + 0.25 * noise(float(i) + seed * 2.0 + 32.0);
    z = z.yzwx;
    m = coef.x*z.x*z.x + coef.y*z.y*z.y + coef.z*z.z*z.z + coef.w*z.w*z.w;
    if (i > 0) {
      a += w * exp(-abs(m - l));
      w *= 0.8 + 0.2 * (2.0 * noise(seed + 3.3 * float(i)) - 1.0);
    }
    l = m;
  }
  float baseVal = max(0.0, 0.5 + 0.5 * sin(freq * a));
  float base = gain(pow(baseVal, max(0.01, power)), 4.0);
  // Mountains on top of the continents. mountain=0 returns the base exactly;
  // larger mountain lifts ridges toward the top of the range WITHOUT exceeding
  // it (so raising the amplitude adds relief instead of clipping flat peaks).
  float ridge = genRidge(p);
  float h = base + mountain * ridge * (1.0 - base);
  h += crater * genCraters(p);
  return clamp(h, 0.0, 1.0);
}

void main() {
  vec3 p = cubeMapDir(uv);
  vec4 c = vec4(genHeight(p), genColor(p), genClouds(p), 0.0);
  if (isnan(c.r) || isnan(c.g) || isnan(c.b) || isnan(c.a)) {
    c = vec4(0.0);
  }
  fragColor = clamp(c, vec4(0.0), vec4(10.0));
}
