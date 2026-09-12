/* --- Here Lies Magic <3 --------------------------------------------------- */

#include fragment
#include color
#include math
#include noise
#include texcube

#define ENABLE_HORIZON 0

layout(location = 0) out vec4 fragColor;
uniform vec3 color;
uniform sampler1D lutR;
uniform sampler1D lutG;
uniform sampler1D lutB;
uniform float roughness;
uniform float seed;

const float kScale      = 0.040;
const float kSamples    = 48.00;
const int kIterations   = 16;

const float kBrightConstant = 0.001;
const float kBrightCell     = 0.0005;

/* Thanks Kali! :) Kaliset 4D extension with noise injection & warping. */
float magic(vec3 p) {
  vec4 z = vec4(vec3(0.53) + p, 0.0);
  float a = 0.0, l = 0.0, tw = 0.0, w = 1.0;
  vec4 c = vec4(0.5, 0.55, 0.45, 0.6);
  for (int i = 0; i < kIterations; ++i) {
    float m = max(dot(z, z), 1e-5);
    z = abs(z) / m - c;
    z += 0.02 * log(max(1.e-10 + noise4(float(i) + seed), vec4(1e-6)));
    z += 0.25 * sin(z);
    a += w * exp(-2.0 * pow2(l - m));
    tw += w;
    if (i > 3) w *= roughness;
    l = m;
    c = c.yzwx;
  }
  return 0.5 + 0.5 * min(cos(30.0 * a / max(tw, 1e-5)), sin(40.0 * a / max(tw, 1e-5)));
}

float bgDensity(vec3 p) {
  return kBrightConstant + kBrightCell * fSmoothNoise(p * 4.0 + seed, 4, 2.0);
}

vec4 generate(vec3 dir) {
  float stretch = 1.0 + exp(-8.0 * abs(dir.y));
  vec3 c = vec3(0.0);
  c += vec3(bgDensity(dir));
  #if ENABLE_HORIZON
    c *= stretch;
  #endif
  float opacity = 1.0;
  float w = 1.0 / float(kSamples);

  /* Central Star. */ {
    float d = max(0.0, 1.0 - dot(dir, starDir));
    float dd = 0.0;
    dd += 8.0 * exp(-sqrt(4096.0 * d));
    dd += 4.0 * exp(-sqrt(sqrt(1024.0 * d)));
    c += dd * color;
  }

  /* Absorption. */ {
    vec3 cEmit = color;
    dir *= kScale;
    #if ENABLE_HORIZON
      dir *= stretch;
    #endif
    for (float i = 0.0; i < kSamples; ++i) {
      vec3 p = dir * i * w;
      float t = magic(p);
      t = exp(-t * t);
      vec3 wave = vec3(
        texture(lutR, t).x,
        texture(lutG, t).x,
        texture(lutB, t).x);
      wave *= sqrt(max(wave, vec3(0.0)));

      const float k = 6.0;
      const float q = 1.2;
      vec3 vs = exp(-q * wave * t);
      vs -= 1.25 *         exp(-pow(8.0 * abs(t - 0.90), 0.75));
      vs += 0.50 * cEmit * exp(-pow(10.0 * abs(t - 0.90), 0.50));
      c *= exp(-k * w * vs);
      opacity *= exp(-k * w * avg(vs));
    }
  }

  return vec4(max(c, vec3(0.0)), clamp(opacity, 0.0, 1.0));
}

void main() {
  vec3 dir = cubeMapDir(uv);
  vec4 c = generate(dir);
  if (isnan(c.r) || isnan(c.g) || isnan(c.b) || isnan(c.a)) {
    c = vec4(0.0, 0.0, 0.0, 1.0);
  }
  fragColor = clamp(c, vec4(0.0), vec4(10.0));
}
