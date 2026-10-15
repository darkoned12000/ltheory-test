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
uniform float cloudWindRate;// advection rate in rad/s = spinSpeed * render.planet.cloudWind
uniform float cloudHeight;  // shell altitude as a FRACTION of rPlanet (0 = flat deck, no parallax)
uniform float cloudShadow;  // how much the deck dims the sun term (0 = no shadowing)
uniform vec3  planetAxisX;  // world-space directions of the planet's local axes. The cube is
uniform vec3  planetAxisY;  // authored in LOCAL space (so the deck spins with the body), so
uniform vec3  planetAxisZ;  // sampling the cloud shell needs world -> local. Passed explicitly
                           // rather than reusing mWorldIT: no fragment shader has ever declared
                           // that autovar, and an unset one is silently identity (see 12).
uniform float terminator;   // 0 = cosine (physical), 1 = flat wrap (legacy)

// World-space direction -> the planet's local direction, and back. Valid for any
// rigid transform; uniform scale cancels under normalize().
vec3 worldToLocalDir (vec3 w) {
  return vec3(dot(w, planetAxisX), dot(w, planetAxisY), dot(w, planetAxisZ));
}
vec3 localToWorldDir (vec3 l) {
  return planetAxisX * l.x + planetAxisY * l.y + planetAxisZ * l.z;
}

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

  // ---- Cloud shadow (W7a) -------------------------------------------------
  // The deck drawn further down also BLOCKS the sun, so dim the sun term by
  // whatever the deck covers along the direction to the star. Same shell, same
  // baked field, same wind drift -- just a second ray-sphere solve along the sun
  // instead of along the view ray. One extra cube fetch on a texture that is
  // already bound; no new pass, no new render target.
  //
  // It has to be computed HERE, before sunLit, because the deck block runs after
  // and mixes over the finished surface colour.
  //
  // The drift is anchored to the SURFACE tangent basis and built once, so the
  // shadow and the deck above it sample the same moving field and line up. (The
  // two sit at slightly different shell points, which is correct -- the cloud
  // casting a shadow at P is the one along the sun ray, not the one overhead --
  // but both must apply the drift to a UNIT DIRECTION, or they desynchronise.
  // See the shadow sample below.)
  vec3 cloudDrift = vec3(0.0);
  float cloudShade = 1.0;
  vec3 nl0 = normalize(vertPos);
  if (clouds > 0.001) {
    vec3 dtl = normalize(cross(nl0, (abs(nl0.y) < 0.9) ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0)));
    vec3 dbl = cross(nl0, dtl);
    // Prevailing drift: mostly along the tangent with a little across it, so the
    // deck does not read as a rigid rotation of the whole pattern. The RATE is
    // cloudWindRate (rad/s, derived from this planet's spin) rather than a fixed
    // constant -- see the note in Planet.lua on why an absolute rate was
    // invisible against a 0.01-0.05 rad/s spin and varied 5x between worlds.
    cloudDrift = normalize(dtl + dbl * 0.4) * (cloudTime * cloudWindRate);
  }
  if (clouds > 0.001 && cloudHeight > 1e-6 && cloudShadow > 0.001) {
    // starDir is WORLD space (it points at the star and does not spin with the
    // body), and vertPos is local -- so convert, or the shadow would be cast by
    // a sun fixed to the planet's own frame and would never sweep as it rotates.
    vec3 Ll = normalize(worldToLocalDir(L));
    float NL = dot(nl0, Ll);
    // As the sun approaches the horizon this ray grazes the shell and the hit
    // point runs away toward infinity, sampling somewhere arbitrary. Fade the
    // shadow out well before that, so the terminator stays clean.
    float shFade = smoothstep(0.06, 0.32, NL);
    if (shFade > 0.001) {
      // Ray from the surface point along Ll, against a sphere centred on the
      // planet's LOCAL origin (which is the centre), so the solve is the simple
      // closed form:  t = -b + sqrt(b^2 - R^2 + rShell^2),  b = vertPos . Ll
      float Rl  = length(vertPos);
      float rSh = Rl * (1.0 + cloudHeight);
      float b   = dot(vertPos, Ll);
      float disc = b * b - Rl * Rl + rSh * rSh;
      if (disc > 0.0) {
        float t = -b + sqrt(disc);          // +root: outward, toward the star
        // Normalise the shell hit point to a UNIT DIRECTION *before* adding the
        // drift, or the drift is swamped by the radius and the shadow stops
        // tracking its own deck. `vertPos + Ll*t` has magnitude ~rPlanet (~1e5),
        // so adding a drift of order 0.1 there shifts the normalised sample by
        // ~1e-6 rad while the deck -- which adds the SAME drift to a unit vector
        // -- shifts by the full 0.1 rad. The two desynchronise and the shadow
        // reads as a second sphere counter-rotating against the clouds above it.
        // This was invisible at cloudWind = 0 because neither term moved.
        vec3 sp = normalize(normalize(vertPos + Ll * t) + cloudDrift);
        float sd = texture(surface, sp).z;
        float scov = smoothstep(0.70 - 0.20 * clouds, 0.95 - 0.20 * clouds, sd);
        cloudShade = 1.0 - cloudShadow * scov * shFade;
      }
    }
  }

  vec3 sunLit = sunColor * (sun * sunScale) * cloudShade;
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
  //
  // The deck sits on a SHELL at rPlanet * (1 + cloudHeight) rather than being
  // projected onto the ground. v1 sampled the field at the surface direction, so
  // the clouds were welded to the terrain and had no parallax: move the camera
  // and the deck moved with the ground underneath it, which reads as painted-on.
  // Intersecting the view ray with the shell gives each surface fragment the
  // direction of the cloud actually in front of it.
  if (clouds > 0.001) {
    vec3 nL = normalize(vertPos);

    // Shell sample direction. cloudHeight <= 0 degenerates to the v1 lookup
    // exactly, so the knob is a clean A/B against the old behaviour.
    vec3 cloudL = nL;
    if (cloudHeight > 1e-6) {
      float rShell = rPlanet * (1.0 + cloudHeight);
      vec3 oc   = eye - origin;
      vec3 rd   = normalize(pos - eye);        // eye -> fragment
      float bq  = dot(oc, rd);
      float cq  = dot(oc, oc) - rShell * rShell;
      float disc = bq * bq - cq;
      if (disc > 0.0) {
        float sq = sqrt(disc);
        // Nearest root in front of the eye. When the camera is inside the shell
        // (cq > 0) the near root is behind us, so take the far one.
        float tHit = -bq - sq;
        if (tHit <= 0.0) tHit = -bq + sq;
        if (tHit > 0.0) {
          // Shell point, expressed FROM THE PLANET CENTRE: eye + rd*tHit - origin.
          // `oc` is already (eye - origin), so this is oc + rd*tHit. Writing
          // `origin - eye + ...` here negates oc and puts the sample on the far
          // side of the body.
          vec3 hitW = normalize(oc + rd * tHit);
          vec3 hitL = normalize(worldToLocalDir(hitW));
          // Fade the parallax out at grazing angles. Near the limb the shell
          // offset grows without bound and smears the whole deck into radial
          // streaks; there the deck is essentially edge-on anyway, so fall back to
          // the ground direction. This is the same reason relief mapping needs a
          // step-count budget at silhouettes.
          float graze = abs(dot(rd, normalize(pos - origin)));
          float fade  = smoothstep(0.02, 0.30, graze);
          cloudL = normalize(mix(nL, hitL, fade));
        }
      }
    }

    // Drift comes from the surface tangent basis, built once above so the deck
    // and the shadow it casts share one field. Rebuilding a basis from cloudL
    // here would shear the deck against its own shadow at every altitude.
    float cd = texture(surface, normalize(cloudL + cloudDrift)).z;
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
    // clamp() matters now that `clouds` can exceed 1 (it parameterises the coverage
    // window, not a literal fraction). mix() with t > 1 EXTRAPOLATES past
    // cloudLit, so an unclamped cov*clouds would push the deck brighter than the
    // cloud colour itself.
    color = mix(color, cloudLit, clamp(cov * clouds, 0.0, 1.0));
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
