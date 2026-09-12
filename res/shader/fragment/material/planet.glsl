#include fragment
#include deferred
#include math
#include color
#include noise
#include scattering2

#autovar vec3 eye
#autovar vec3 starDir

uniform samplerCube surface;
uniform vec3 origin;
uniform vec3 color1;
uniform vec3 color2;
uniform vec3 color3;
uniform vec3 color4;
uniform float heightMult;
uniform float oceanLevel;

const float kSpecular = 1.0;
const vec3 kOceanColor = vec3(0.01, 0.13, 0.20);

float heightFn(float h, int octaves, float roughness) {
  float total = 1.0;
  float tw = 0.0;
  float f = PI;
  float w = 1.0;
  float off = 17.371;

  for (int i = 0; i < octaves; ++i) {
    total += w * (0.5 + 0.5 * sin(f * h + off));
    tw += w;
    w *= roughness;
    f *= 2.00;
    off += 2.3337;
  }
  total /= max(1e-5, tw);
  return 1.0 - exp(-2.0 * pow2(max(0.0, total - 0.5)));
}

float visibility(
    samplerCube map, vec3 p, int octaves, float roughness,
    float offset, float radius, float strength, float distFactor)
{
  float starLen = length(starDir);
  vec3 toStar = (starLen > 1e-6) ? -starDir / starLen : vec3(0.0, -1.0, 0.0);

  // Distance-adaptive iteration cap for terrain horizon self-shadowing
  int samples = (distFactor > 5.0) ? 2 : 4;
  float v = 0.0;
  float fSamples = float(samples);

  for (int i = 0; i < 4; ++i) {
    if (i >= samples) break;
    vec3 sp = normalize(mix(p, toStar, radius * (float(i) + 1.0) / fSamples));
    float h = heightFn(texture(map, sp).x, octaves, roughness);
    float rh = h - offset;
    v += exp(-strength * heightMult * max(0.0, rh));
  }
  return v / fSamples;
}

void main() {
  float starLen = length(starDir);
  vec3 L = (starLen > 1e-6) ? starDir / starLen : vec3(0.0, 1.0, 0.0);
  vec3 P = pos - origin;
  vec3 N = normalize(normal);
  vec3 V = normalize(pos - eye);
  float NL = dot(N, L);
  float light = mix(exp(-max(0.0, pow(1.0 - NL, 4.0))), 1.0, 0.01);

  vec4 map = texture(surface, vertPos);
  float safeRPlanet = max(1e-4, rPlanet);
  float dist = length(pos - eye) / safeRPlanet;

  float h1 = heightFn(map.x, 6, 0.70);
  float h2 = heightFn(map.x, 3, 0.20);

  vec3 color = mix(color1, color2, h1);
  color = 1.0 - exp(-pow2(3.0 * color));
  color *= visibility(surface, vertPos, 6, 0.70, h1, 0.002, 2.0, dist);
  color = mix(color, kOceanColor, 1.0 - exp(-sqrt(16.0 * max(0.0, h2 - 0.8))));
  color *= light;

  vec4 atmo = atmosphereDefault(V, eye - origin);
  color = atmo.xyz + color * (1.0 - atmo.w);

  if (isnan(color.r) || isnan(color.g) || isnan(color.b)) {
    color = vec3(0.0);
  }

  FRAGMENT_CORRECT_DEPTH;

  setAlbedo(clamp(color, vec3(0.0), vec3(1.0)));
  setAlpha(1.0);
  setDepth();
  setNormal(N);
  setRoughness(1.0);
  setMaterial(Material_NoShade);
}
