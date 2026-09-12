#include fragment
#include color
#include math
#include noise
#include texcube
#include quat

layout(location = 0) out vec4 fragColor;
uniform float density;
uniform float seed;
uniform vec4 rot;
uniform samplerCube src;

const int kIterations = 12;

float magic(vec3 p) {
  vec4 z = vec4(vec3(0.53) + p, 0.0);
  float a = 0.0, l = 0.0, tw = 0.0, w = 1.0;

  vec4 c = vec4(0.21, 0.49, 0.52, 0.48);
  for (int i = 0; i < kIterations; ++i) {
    float m = max(dot(z, z), 1e-5);
    z = abs(z) / m - c;
    z += 0.20 * (2.0 * noise4(float(i) + seed) - 1.0);
    z += 0.25 * sin(z);
    a += w * exp(-pow2(m - l));
    tw += w;
    w = 1.0 / float((1 + i) * (1 + i));
    l = m;
    c = c.yzwx;
  }
  a /= max(tw, 1e-5);
  a = 4.0 * density * pow2(max(0.0, a - 0.5) / 0.5);
  return max(0.0, a);
}

void main() {
  vec3 dir = cubeMapDir(uv);
  vec4 radiance = texture(src, dir);
  dir = quatMul(rot, dir);
  float od = magic(dir);

  vec3 safeRad = max(vec3(1e-4), radiance.xyz);
  radiance.xyz *= exp(-od / safeRad);
  radiance.w += od;

  if (isnan(radiance.r) || isnan(radiance.g) || isnan(radiance.b) || isnan(radiance.w)) {
    radiance = vec4(0.0);
  }
  fragColor = clamp(radiance, vec4(0.0), vec4(100.0));
}
