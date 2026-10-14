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
uniform float atmoSun;      // engine sun intensity x scattering gain (see atmosphereDefault)
uniform float clouds;       // cloud coverage: type.weather x panel knob x per-planet bias (0 = none)
uniform float cloudTime;    // seconds; advects the cloud lookup (wind)
uniform float terminator;   // 0 = cosine (physical), 1 = flat wrap (legacy)

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
  // Terminator shape. The old curve, exp(-(1-NL)^4), stays within 6% of full
  // brightness until NL ~ 0.5 and STILL reads 37% at the geometric limb, so the
  // lit hemisphere glows almost to the edge: the planet looks lit by a broad
  // source, and the bright limb region reads as a light source sitting on it.
  // Blend toward a true cosine law, which dims the limb and rounds the day side.
  // `terminator` = 0 is pure Lambert (physically correct for a diffuse surface,
  // with a hard day/night edge); 1 is the old flat wrap. Default 0.35 keeps a
  // little softness for the atmosphere-lit twilight band.
  float nlCos   = max(0.0, NL);
  float nlSoft  = mix(exp(-max(0.0, pow(1.0 - NL, 4.0))), 1.0, 0.01);
  float light = mix(nlCos, nlSoft, terminator);

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
  // NOTE: named `surfCol`, not `surface` -- a local `vec3 surface` here would
  // shadow the samplerCube uniform of the same name for the rest of main(), so
  // every later `texture(surface, ...)` would fail to compile. That is why the
  // height-gradient fetches above all sit BEFORE this line.
  vec3 surfCol = color;
  float sun = clamp(light, 0.0, 1.0);
  vec3 sunLit = sunColor * (sun * sunScale);
  // Skybox fill on the night side. irMap is a progressive-blur chain (mip 0 =
  // raw env, higher mips = wider-cap average), so a LOW mip is the directional
  // answer. This was 5.0, which measured only ~4.8:1 contrast between the
  // brightest and darkest directions on the 1024 nebula cube and lifted the
  // darkest 5% of directions from 13 to 25 -- i.e. light arriving from
  // everywhere. Mip 3 restores ~7.9:1 for a barely different median, so the
  // night side gets darker where it faces empty sky and picks up the nebula
  // where it actually is.
  vec3 amb = linear(textureLod(irMap, N, 3.0).xyz) * envAmbient;
  float sunOn = clamp(max(max(sunColor.r, sunColor.g), sunColor.b), 0.0, 1.0);
  // Fill the side the sun isn't lighting. `mix` keeps the nebula UNIFORM when
  // the sun is off; the 0.85 floor leaves a touch of ambient in day-side
  // terrain shadows so they aren't pure black.
  color = surfCol * (sunLit + amb * mix(1.0, 1.0 - 0.85 * sun, sunOn));

  // Clouds (Phase C). genClouds() has baked a seeded, per-planet cloud field into
  // the surface cube's BLUE channel since the generator was first written -- the
  // material simply never read it, so every planet was paying to generate a field
  // nobody saw. Wind is an advection of the sample point across that baked 3D
  // field: the field is a fractal of the LOCAL direction, so sliding the lookup
  // along the local tangents reads as a drifting deck with no extra texture, no
  // second cube and no regeneration. Skipped entirely when clouds == 0, which is
  // every airless body (barren type / moons carry weather = 0).
  if (clouds > 0.001) {
    vec3 nL = normalize(vertPos);
    vec3 tL = normalize(cross(nL, (abs(nL.y) < 0.9) ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0)));
    vec3 bL = cross(nL, tL);
    // Prevailing drift: mostly along tL with a little across it, so the deck does
    // not read as a rigid rotation of the whole pattern.
    vec3 drift = normalize(tL + bL * 0.4) * (cloudTime * 2.0e-4);
    float cd = texture(surface, normalize(vertPos + drift)).z;
    // Coverage window sits HIGH in the field's range: genClouds returns
    // 0.5 + 0.5*sin(...), so a window centred near 0.5 blankets the planet and
    // reads as a bleached shell with the surface only as dark blotches. Biomes
    // should dominate and the deck band them.
    float cov = smoothstep(0.70 - 0.20 * clouds, 0.95 - 0.20 * clouds, cd);
    // Lit by the sphere's own day/night (a cloud deck has no terrain to cast on
    // it), on the same sun + ambient terms the surface uses. 1.25x albedo, not
    // more: the deck is bright, but pushing it past ~1.3 blows the disc out on a
    // backlit planet where the atmosphere shell is already adding scatter.
    float cNL = max(0.0, dot(N, L));
    // 1.05 deck albedo, and the sun term scaled by the same terminator shape as
    // the ground so the deck does not keep glowing out past the limb.
    vec3 cloudLit = (sunColor * sunScale * (0.15 + 0.85 * cNL * (1.0 - 0.5 * terminator)) + amb) * 1.05;
    color = mix(color, cloudLit, cov * clouds);
  }

  if (hasAtmo > 0.5) {
    vec4 atmo = atmosphereDefault(V, eye - origin, atmoSun);
    // starColor (hue) and atmoSun (intensity) are mirrored from render.sun.*,
    // then gated by the engine sun colour so 'Sun Light' off darkens the planet
    // instead of leaving a glowing shell.
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
