#include fragment
#include deferred
#include math
#include color
#include noise
#include gamma
#include scattering2

#autovar vec3 eye
#autovar vec3 starDir
#autovar vec3 sunColor
#autovar samplerCube irMap

uniform samplerCube surface;
uniform vec3 origin;
uniform vec3 color1;
uniform vec3 color2;
uniform vec3 color3;
uniform vec3 color4;
uniform float heightMult;
uniform float oceanLevel;
uniform float hasAtmo;      // 1 = planet (scatter), 0 = airless moon/barren
uniform float relief;       // normal-perturbation strength (0 = flat shading)
uniform vec3  emissive;     // self-lit colour (lava); (0,0,0) = none
uniform float emissiveAmt;  // emissive strength (0 = off)
uniform float envAmbient;   // skybox irradiance scale for the night side
uniform vec3  sunColor;     // engine sun colour (Sun Light enable/intensity/warmth baked in)
uniform float sunScale;     // extra per-planet sun brightness scale
uniform float atmoGlow;     // atmosphere scattering brightness (0 = no glow, 1 = default)

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
  // starDir points TOWARD the star (the nebula bakes its glow at +starDir), and
  // main() shades with +starDir as L — so self-shadowing must march the same
  // way. (Was -starDir: terrain shadows were computed toward the anti-sun.)
  vec3 toStar = (starLen > 1e-6) ? starDir / starLen : vec3(0.0, 1.0, 0.0);

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

  vec4 map = texture(surface, vertPos);
  float safeRPlanet = max(1e-4, rPlanet);
  float dist = length(pos - eye) / safeRPlanet;

  float h1 = heightFn(map.x, 6, 0.70);
  float h2 = heightFn(map.x, 3, 0.20);

  // Relief shading: perturb the normal from the height gradient. Use a SMOOTH
  // (low-octave) height over a WIDE step: the gradient must stay low-frequency
  // or it aliases into shimmer at 1x sampling (which only supersampling hid).
  float hr = heightFn(map.x, 3, 0.5);
  vec3 T = normalize(cross(N, (abs(N.y) < 0.9) ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0)));
  vec3 B = cross(N, T);
  float eps = 0.004;
  float hU = heightFn(texture(surface, normalize(vertPos + T * eps)).x, 3, 0.5);
  float hV = heightFn(texture(surface, normalize(vertPos + B * eps)).x, 3, 0.5);
  vec3 Np = normalize(N - relief * ((hU - hr) * T + (hV - hr) * B));

  float NL = dot(Np, L);
  float light = mix(exp(-max(0.0, pow(1.0 - NL, 4.0))), 1.0, 0.01);

  // 4-stop biome ramp: low -> mid -> high -> peak (snow/ice caps etc.).
  vec3 color = mix(color1, color2, smoothstep(0.0, 0.45, h1));
  color = mix(color, color3, smoothstep(0.45, 0.75, h1));
  color = mix(color, color4, smoothstep(0.75, 1.0, h1));
  color = 1.0 - exp(-pow2(3.0 * color));
  color *= visibility(surface, vertPos, 6, 0.70, h1, 0.002, 2.0, dist);
  // Waterline from the planet TYPE: oceanLevel 0 = no water, 1 = all water.
  float waterline = 1.0 - clamp(oceanLevel, 0.0, 1.0);
  color = mix(color, kOceanColor, 1.0 - exp(-sqrt(16.0 * max(0.0, h2 - waterline))));

  // Sun (self-lit) + ENVIRONMENT ambient. The planet is Material_NoShade, so the
  // engine's deferred light passes skip it (light/global.glsl passes it straight
  // through) — it must consume sunColor itself. sunColor is (0,0,0) when
  // 'Sun Light' is off, so the sun term goes dark and the nebula becomes a
  // UNIFORM fill instead of a hard addend that blew out the day side.
  vec3 surface = color;
  float sun = clamp(light, 0.0, 1.0);
  vec3 sunLit = sunColor * (sun * sunScale);
  vec3 amb = linear(textureLod(irMap, N, 5.0).xyz) * envAmbient;
  float sunOn = clamp(max(max(sunColor.r, sunColor.g), sunColor.b), 0.0, 1.0);
  // Fill the side the sun isn't lighting. `mix` keeps the nebula UNIFORM when
  // the sun is off; the 0.85 floor leaves a touch of ambient in day-side
  // terrain shadows so they aren't pure black.
  color = surface * (sunLit + amb * mix(1.0, 1.0 - 0.85 * sun, sunOn));

  if (hasAtmo > 0.5) {
    vec4 atmo = atmosphereDefault(V, eye - origin);
    // scattering2 is a SECOND, hardcoded sun (iSun=22, its own starColor) and
    // ignores render.sun.*. Gate its colour with the engine sun so 'Sun Light'
    // off actually darkens the planet instead of leaving a glowing atmosphere.
    atmo.xyz *= sunOn * atmoGlow;
    color = atmo.xyz + color * (1.0 - atmo.w);
  }

  // Emissive (lava): molten cracks glow where the terrain is low. emissiveAmt
  // is 0 for every non-lava type, so this is a no-op elsewhere.
  float emisMask = 1.0 - smoothstep(0.05, 0.40, h1);
  color += emissive * emissiveAmt * emisMask;

  if (isnan(color.r) || isnan(color.g) || isnan(color.b)) {
    color = vec3(0.0);
  }

  FRAGMENT_CORRECT_DEPTH;

  // No upper clamp: the albedo G-buffer is RGBA16F, so sun-lit highlights (>1)
  // roll off through the tonemapper instead of hard-clipping to a flat white disc.
  setAlbedo(max(color, vec3(0.0)));
  setAlpha(1.0);
  setDepth();
  setNormal(Np);
  setRoughness(1.0);
  setMaterial(Material_NoShade);
}
