#include fragment
#include deferred
#include math
#include color
#include noise
#include gamma
#include scattering2
#include planetlocal

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
uniform float stormAmount;  // storminess 0..1 (per-type weather prior x panel knob)
uniform float stormFlash;   // intra-cloud lightning brightness (0 = none)
uniform float auroraAmt;    // auroral emission 0..1 (0 = none; type-gated, see Planet.lua)
uniform float auroraHeight; // lower shell altitude as a FRACTION of rPlanet
// planetAxisX/Y/Z and the world<->local direction helpers now live in
// include/planetlocal, shared with material/ring.glsl.
uniform vec3  planetSpinAxis;// the body's own spin axis; the drift tangent basis is built
                             // from it so it cannot jump across a latitude circle (see below)
                           // rather than reusing mWorldIT: no fragment shader has ever declared
                           // that autovar, and an unset one is silently identity (see 12).
uniform float terminator;   // 0 = cosine (physical), 1 = flat wrap (legacy)

// Rodrigues rotation of a DIRECTION about the body's spin axis. This is the
// cloud drift. Three properties the old `normalize(dir + D*drift)` construction
// did not have, and all three were bugs:
//   * isometric -- |out| == |in| exactly, so the sample direction can never be
//     dominated (and never collapses toward a fixed direction),
//   * periodic in `ang`, so it wraps mod 2*pi rather than growing without bound,
//   * constant angular rate, rather than decaying like atan(D).
// There is no tangent frame here at all, so nothing can be discontinuous across
// a latitude circle.
vec3 driftRotate (vec3 d, float ang) {
  vec3 a = normalize(planetSpinAxis);
  float c = cos(ang), s = sin(ang);
  return d * c + cross(a, d) * s + a * dot(a, d) * (1.0 - c);
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
  // Relief tangent frame, built from the planet's SPIN AXIS for the same reason
  // the cloud drift is (11.14): this used to be
  //     cross(N, (abs(N.y) < 0.9) ? vec3(0,1,0) : vec3(1,0,0))
  // whose branch boundary is the latitude circle |N.y| = 0.9 (asin 0.9 = 64.2
  // deg) -- and cross(N,+Y) and cross(N,+X) are unrelated, so the height gradient
  // below SHEARED discontinuously there. That is a visible arc in the TERRAIN
  // shading, near the top of the disc, and it predates the cloud work entirely.
  vec3 rAx   = normalize(planetSpinAxis);
  vec3 tRaw  = cross(N, rAx);
  float rTl  = length(tRaw);
  // rTl is tiny only within a fraction of a degree of the spin pole, so the
  // fallback branch covers a single point -- and reliefFade zeroes the
  // perturbation there anyway, so the branch can never be seen.
  vec3 T = (rTl > 1e-3) ? tRaw / rTl : cross(N, vec3(1.0, 0.0, 0.0));
  vec3 B = cross(N, T);
  float eps = 0.004;
  float hU = heightFn(texture(surface, normalize(vertPos + T * eps)).x, 3, 0.5);
  float hV = heightFn(texture(surface, normalize(vertPos + B * eps)).x, 3, 0.5);
  // Fade the perturbation out where the tangent is undefined ("eastward" has no
  // meaning at the pole) so nothing can pop there.
  float reliefFade = smoothstep(0.0, 0.05, rTl);
  vec3 Np = normalize(N - relief * reliefFade * ((hU - hr) * T + (hV - hr) * B));

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
  float cloudDriftAng = 0.0;
  float cloudShade = 1.0;
  vec3 nl0 = normalize(vertPos);
  if (clouds > 0.001) {
    // Drift is a ROTATION about the body's own spin axis, not a translation.
    //
    // The old form built a tangent basis and did `normalize(dir + D*driftdir)`
    // with D = cloudTime * cloudWindRate growing without bound. Because
    // normalize() discards magnitude, every fragment's sample direction tends to
    // driftdir as D grows -- and driftdir sits at a FIXED angle off the
    // equatorial plane. So all latitudes collapsed together: +80 and -80 degrees
    // both landed at -21.8, the equator at 0, and the whole deck squeezed into one
    // band. That is the "wind going down a drain" -- it got worse as the Wind
    // slider rose, because a larger rate reaches the collapse sooner.
    //
    // A rotation has none of those problems: it is an ISOMETRY (|d| stays 1), it
    // is periodic in the angle so it wraps mod 2pi instead of growing, and its
    // angular rate is constant forever instead of decaying as atan(D). Zonal
    // drift is also the physically dominant term, and it correctly goes to zero
    // at the poles on its own.
    //
    // It also removes the tangent basis entirely, which is what produced the
    // "circle" in 11.14 -- there is no longer a per-fragment frame to be
    // discontinuous.
    cloudDriftAng = cloudTime * cloudWindRate;
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
        vec3 sp = driftRotate(normalize(vertPos + Ll * t), cloudDriftAng);
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
    float cd = texture(surface, driftRotate(cloudL, cloudDriftAng)).z;
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

    // ---- Storms -----------------------------------------------------------
    // Storminess is a much LOWER-frequency field than the deck texture, so a
    // storm reads as a whole weather system rather than as cloud detail. NASA
    // astronaut photography of storms from orbit consistently shows the
    // convective cells as DARKER than the surrounding deck -- thick anvils
    // absorb, they do not scatter more -- so storminess multiplies the deck
    // albedo down rather than brightening it.
    float stormField = fSmoothNoise(driftRotate(cloudL, cloudDriftAng * 0.5) * 3.1
                                    + vec3(91.3, 17.7, 43.1), 3, 2.0);
    float storm = smoothstep(0.50, 0.80, stormField) * stormAmount;

    // Intra-cloud lightning. Quantise the (drifted) sample direction into storm
    // cells and hash the cell against the current TIME WINDOW, so each cell
    // flashes independently and out of phase -- the planet twinkles rather than
    // strobing in unison. Windows are short so the envelope decays inside one.
    //
    // The cell grid is only a way to give each region its OWN flash timing; it
    // must never be visible. Quantising a unit direction with floor() makes
    // axis-aligned PLANAR cells, so a firing cell lit a visible white SQUARE
    // with hard edges (seen 2026-10-15). The position within the cell gives a
    // smooth window that is 0 at every border, so a flash fades out before it
    // reaches an edge and the grid can never be seen.
    const float cellSize = 0.15;   // ~8 deg across, i.e. storm-cell scale
    const float winDur   = 1.6;
    vec3  cellC = driftRotate(cloudL, cloudDriftAng) / cellSize;
    vec3  cell  = floor(cellC);
    vec3  cf    = fract(cellC);
    // A NARROW peak. The window was 0.30-0.70, which leaves a wide flat top, so
    // the interior of a firing cell was a nearly-uniform patch: invisible at
    // planet scale but an obvious rounded rectangle when the camera is close
    // enough to magnify a cell across a third of the screen. Confirmed by
    // capture at 1.15x radius with cloudHeight 0.12.
    vec3  cw    = smoothstep(0.0, 0.45, cf) * (1.0 - smoothstep(0.55, 1.0, cf));
    float cellWin = cw.x * cw.y * cw.z;
    float win   = floor(cloudTime / winDur);
    float ph    = fract(cloudTime / winDur);
    float hsh   = fract(sin(dot(cell + win, vec3(12.9898, 78.233, 37.719))) * 43758.5453);
    // ~7% of cells fire per window; fast attack, exponential decay.
    float fire  = step(0.86, hsh);  // ~14% of cells per window
    // Decay rate sets how long a flash is visible. exp(-ph*8) left it significant
    // for only ~0.4 s of each 1.6 s window, which is physically right but easy
    // to miss entirely -- two of three sampled frames landed in the dead part
    // of the envelope. 5.0 keeps it a FLASH rather than a glow while making it
    // unmistakable in motion.
    float env   = fire * smoothstep(0.0, 0.04, ph) * exp(-ph * 5.0);
    // Only inside a storm, and only where there is actually cloud to light.
    // `flick` breaks the cell's remaining square footprint: even with the border
    // window, a flat cellWin still lights a rounded SQUARE, which is visible as
    // a faint grey patch. High contrast on purpose -- a real intra-cloud flash
    // is a small bright speck, not a dim even wash, and low-contrast modulation
    // left the cell readable as a shape when magnified.
    float flick = 0.12 + 0.88 * fSmoothNoise(driftRotate(cloudL, cloudDriftAng) * 7.0
                                              + vec3(cloudTime * 3.0), 3, 2.0);
    float flash = env * storm * cov * cellWin * flick * stormFlash;

    // Storm cells darken the deck, then the flash briefly overdrives it.
    // `storm` MUST be clamped before it drives a mix() factor: stormAmount is
    // the weather prior times the knob, so it exceeds 1 whenever the knob is
    // above 1/weather (at storms = 3 on a 0.60 world it reaches 1.8), and an
    // unclamped mix(1.0, 0.45, 1.8) EXTRAPOLATES to 0.01 -- cells went almost
    // black and swamped the flashes entirely (2026-10-15).
    float stormMix = clamp(storm, 0.0, 1.0);
    cloudLit *= mix(1.0, 0.45, stormMix);
    // Clamp the flash too, so a firing cell cannot push the deck past a
    // plausible albedo and blow out through the bloom threshold.
    cloudLit += vec3(0.85, 0.90, 1.00) * min(flash, 0.8) * 3.2;
    // clamp() matters now that `clouds` can exceed 1 (it parameterises the coverage
    // window, not a literal fraction). mix() with t > 1 EXTRAPOLATES past
    // cloudLit, so an unclamped cov*clouds would push the deck brighter than the
    // cloud colour itself.
    color = mix(color, cloudLit, clamp(cov * clouds, 0.0, 1.0));
    // A flash inside the deck lights the ground beneath it too. Small, and only
    // where the deck is thin enough to pass light down, which is what stops it
    // reading as a glow painted on the surface.
    color += vec3(0.85, 0.90, 1.00) * flash * 0.35 * (1.0 - cov);
  }

  if (hasAtmo > 0.5) {
    vec4 atmo = atmosphereDefault(V, eye - origin, atmoSun);
    // starColor (hue) and atmoSun (intensity) are mirrored from render.sun.*,
    // then gated by the engine sun colour so 'Sun Light' off darkens the planet
    // instead of leaving a glowing shell.
    atmo.xyz *= sunOn * atmoGlow;
    color = atmo.xyz + color * (1.0 - atmo.w);
  }

  // ---- Aurorae -----------------------------------------------------------
  // Grounded in ISS observations (see ltheory-planets.md 11.13): green emission
  // occupies 100-300 km and red sits ON TOP of it at 300-500 km; the display
  // forms concave arcs tens of degrees across, centred on the magnetic pole, in
  // an oval at high latitude; activity peaks ~180 degrees from the sun; and the
  // whole thing "crawls around like a giant green amoeba" rather than sitting
  // still.
  //
  // The two colours are put on TWO SHELLS rather than one, which gets the
  // vertical structure for free: the higher shell is hit at a different
  // direction whenever the view is off-axis, so red appears offset above green
  // at the limb and directly behind it when looking straight down. That is the
  // same thing the real altitude split does, for one extra ray-sphere solve and
  // no extra texture.
  if (auroraAmt > 0.001) {
    float rAur = rPlanet * (1.0 + auroraHeight);
    float rRed = rPlanet * (1.0 + auroraHeight * 2.2);
    vec3  oc   = eye - origin;
    vec3  rd   = normalize(pos - eye);

    // Auroral oval: a NARROW latitude band, not a polar cap and not a hemisphere.
    // The real oval is a few degrees wide centred near 67 degrees magnetic
    // latitude. The first attempt spanned lat 0.70-0.99 (44-82 degrees), which
    // is not an oval at all -- it washed the entire disc green (2026-10-15).
    // spinAxis is only tilted +/-19 degrees from local +Y (see Planet.lua), so
    // dot(dir, vec3(0,1,0)) is a good latitude.
    float lat = abs(dot(normalize(vertPos), vec3(0.0, 1.0, 0.0)));
    float oval = smoothstep(0.84, 0.90, lat) * (1.0 - smoothstep(0.93, 0.985, lat));
    // Activity peaks 180 degrees from the sun, so weight hard toward night.
    float night = 1.0 - smoothstep(-0.55, 0.10, dot(normalize(vertPos), L));
    // An auroral curtain is optically THIN, so the path length through it is
    // short when you look straight down at it and long when you see it edge-on.
    // That makes it a LIMB feature, which is exactly how it reads from orbit --
    // and it is what stops it painting the disc face-on.
    float limb = 1.0 - abs(dot(V, N));
    float edgeOn = smoothstep(0.12, 0.65, limb);

    if (oval * night * edgeOn > 0.001) {
      // Two advected noise fields: a slow one for the arcs, a faster, finer one
      // for the vertical rays that fringe their edges.
      float t = cloudTime * 0.05;
      vec3  ag = vec3(0.0);
      vec3  bq = vec3(0.0);
      float gHit = 0.0, rHit = 0.0;

      // Lower shell -> green.
      {
        float bqv = dot(oc, rd);
        float dsc = bqv * bqv - (dot(oc, oc) - rAur * rAur);
        if (dsc > 0.0) {
          float s = sqrt(dsc);
          float tH = -bqv - s;
          if (tH <= 0.0) tH = -bqv + s;
          if (tH > 0.0) {
            ag = normalize(worldToLocalDir(normalize(oc + rd * tH)));
            gHit = 1.0;
          }
        }
      }
      // Upper shell -> red.
      {
        float bqv = dot(oc, rd);
        float dsc = bqv * bqv - (dot(oc, oc) - rRed * rRed);
        if (dsc > 0.0) {
          float s = sqrt(dsc);
          float tH = -bqv - s;
          if (tH <= 0.0) tH = -bqv + s;
          if (tH > 0.0) {
            bq = normalize(worldToLocalDir(normalize(oc + rd * tH)));
            rHit = 1.0;
          }
        }
      }

      float band = 0.0, rays = 0.0, rband = 0.0;
      if (gHit > 0.5) {
        band = fSmoothNoise(ag * 5.5 + vec3(t, 0.0, -t), 4, 2.0);
        rays = fSmoothNoise(ag * 21.0 + vec3(-t * 1.7, 0.0, t * 1.7), 3, 2.1);
      }
      if (rHit > 0.5) {
        rband = fSmoothNoise(bq * 4.2 + vec3(t * 0.7, 0.0, -t * 0.7), 3, 2.0);
      }

      // Arc structure: threshold the slow field so the oval breaks into
      // discrete arcs with real gaps. Two thresholds multiplied -- the first
      // picks the arcs, the second cuts holes in them -- because a single
      // saturate() on a fbm field just saturates to 1 over most of the oval.
      float arc = smoothstep(0.36, 0.50, band) * (1.0 - smoothstep(0.60, 0.78, band));
      float ray = 0.45 + 0.55 * saturate(rays * 1.4 - 0.25);
      float g = oval * night * edgeOn * arc * ray;

      // Red is weaker and patchier than green, and only where the upper shell
      // actually differs from the lower one -- so at nadir it hides behind the
      // green instead of tinting it.
      float r = oval * night * edgeOn * smoothstep(0.48, 0.62, rband) * (1.0 - 0.6 * arc);

      // Oxygen green 557.7 nm, oxygen red 630 nm, and a little nitrogen violet
      // where the rays are strongest.
      // Green dominant: from orbit the 557.7 nm oxygen band is what you
      // actually see, and the 630 nm red is a fringe above it. Giving red equal
      // weight turned the arc magenta, which reads as a bug rather than a light.
      vec3 aur = vec3(0.10, 1.00, 0.42) * g * 2.60
               + vec3(1.00, 0.17, 0.28) * r * 0.70
               + vec3(0.50, 0.34, 1.00) * rays * g * 0.40;
      // Additive and unbounded upward: it is emission, and the tonemapper rolls
      // it off rather than clipping it to a flat disc.
      color += aur * auroraAmt;
    }
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
