#include fragment
#include color
#include math
#include noise
#include texcube

layout(location = 0) out vec4 fragColor;

void main() {
  vec3 dir = cubeMapDir(uv);
  float xp = 2.0 * pow2(fSmoothNoise(dir + vec3(2, 3, 5), 3, 1.8)) - 1.0;
  float yp = 2.0 * pow2(fSmoothNoise(dir + vec3(7, 11, 13), 3, 1.8)) - 1.0;
  float zp = 2.0 * pow2(fSmoothNoise(dir + vec3(17, 19, 23), 3, 1.8)) - 1.0;
  vec3 dir2 = normalize(dir + 0.4 * normalize(vec3(xp, yp, zp)));

  const float seed = 1337.0;
  float lac = 1.0 + 1.0 * fSmoothNoise(4.0 * dir + vec3(27, 31, 37), 4, 1.8);
  float thresh = 0.3 * fSmoothNoise(4.0 * dir + vec3(127, 131, 137), 4, 1.8);
  float d = 1.0 - exp(-6.0 * pow2(frCellNoise(1.0 * dir2, seed + 33.3, 4, lac)));
  d = mix(d, 1.0 - exp(-6.0 * pow2(frCellNoise(2.0 * dir, seed, 4, lac))), 0.5);
  d = smoothstep(0.0, 1.0, max(0.0, d - thresh));
  d = saturate(d);
  fragColor = vec4(d);
}
