#ifndef include_medium
#define include_medium

/* Volumetric medium — fog-nebula-implementation.md.
 * Shared by filter/volume.glsl (half-res layer) and filter/volblur.glsl
 * (full-res composite + debug views).
 */
#include math
#include noise

uniform float volDensity;    /* medium master gain                       */
uniform float volBackground; /* background-bank presence (anchors unaffected) */
uniform float volSigmaT;     /* extinction per unit optical depth        */
uniform float volSigmaS;     /* scattering per unit optical depth        */
uniform float volSteps;      /* raymarch step budget (float, 10/20/48)  */
uniform float volDist;       /* max march distance, world units          */
uniform float volMip;        /* log2(fullres / halfres)                  */
uniform float volEvals;      /* noise-eval budget: 2 (Q1/Q2) or 3 (Q3)  */
uniform vec3  volFlow;       /* deterministic world drift, u/s           */
uniform float volTime;       /* seconds                                  */
uniform float volCount;      /* active anchors (bounded, CPU-culled)     */
uniform vec3  volTint;       /* background albedo                        */
uniform float volTintAmt;    /* background tint mix                      */
uniform sampler2D texAnchors;/* RGBA32F rows per anchor                  */

/* Background banks (world-space) — the everywhere-field. volBackground scales
 * presence only (anchors keep their Lua density); without it, a density gain
 * high enough for thick banks also turns the whole sky into drifting wash. */
float mediumDensity (vec3 p) {
  if (volDensity <= 1e-6 || volBackground <= 1e-6) return 0.0;
  // Bounded drift. A true unbounded translation (volFlow * volTime) grows the
  // sample coordinate without limit; noise() hashes with sin(), which loses
  // precision past ~1e4 and degenerates into a stipple (the "green speckle").
  // volTime is also absolute (~1.8e6 s), so the offset hit ~6e7 immediately.
  // Wrap the phase and sway within a bounded range instead.
  float driftT = mod(volTime, 300.0);
  p += volFlow * (10.0 * sin(driftT * 0.02) + 6.0 * sin(driftT * 0.0071 + 1.7));
  float a = smoothNoise(p * 0.0004);
  // March step = radius/steps (~290 units at High). Any noise feature below
  // ~2x that aliases into the "green speckle". Keep the finest octave well
  // above it (0.0008 = 1250-unit features).
  float b = smoothNoise(p * 0.0008);
  float d = smoothstep(0.30, 0.72, 0.66 * a + 0.34 * b);
  if (volEvals >= 2.5) {
    float m = smoothNoise(p * 0.0006 + b * 3.0);
    d *= smoothstep(0.25, 0.9, m);
  }
  return volDensity * volBackground * d;
}

/* Anchor record (see the packing contract in Renderer.lua:volume):
 *   col0 = (pos.xyz, extX)      col1 = (density, scale, warp, extY)
 *   col2 = (coreRGB, extZ)      col3 = (rimRGB, -)
 * NebulaVolumes authors all three extents per plume, so the envelope is an
 * ELLIPSOID, not a sphere of extX -- and it authors a second, darker tone per
 * plume (rim), which is the edge colour of the dual-tone gradient. Both were
 * computed and then dropped on the floor until now.
 */
vec3 anchorExtent (vec4 c, vec4 d, vec4 e) {
  return max(vec3(c.w, d.w, e.w), vec3(1e-4));
}

/* Anchor parameters are INVARIANT along a ray: position, density, scale, warp,
 * colors and extents do not depend on the sample point p. They were re-fetched
 * with 4 texelFetch calls per anchor PER MARCH STEP -- 64 fetches per step, and
 * at Low quality (volSteps 10) ~640 per pixel, all returning byte-identical
 * values for the whole pixel. They are fetched once per fragment here instead.
 *
 * The cache is SELF-ARMING (a bool that GLSL resets to false per fragment) and
 * is invoked from inside anchorEnvelope/cloudSection rather than by an explicit
 * call at each march site, on purpose: there are four call sites (volume,
 * godrays, volblur, mediumOpticalDepth) and a forgotten call would leave every
 * gAnchor* at zero, i.e. delete every plume -- a bug that presents as "the nebula
 * vanished", not as a perf change. */
vec4 gAnchorC[16];
vec4 gAnchorD[16];
vec4 gAnchorE[16];
vec4 gAnchorR[16];
bool gAnchorsCached = false;

void mediumCacheAnchors () {
  if (gAnchorsCached) return;
  gAnchorsCached = true;
  for (int i = 0; i < 16; ++i) {
    if (float(i) + 0.5 >= volCount) break;
    gAnchorC[i] = texelFetch(texAnchors, ivec2(0, i), 0);
    gAnchorD[i] = texelFetch(texAnchors, ivec2(1, i), 0);
    gAnchorE[i] = texelFetch(texAnchors, ivec2(2, i), 0);
    gAnchorR[i] = texelFetch(texAnchors, ivec2(3, i), 0);
  }
}

/* Anchor plumes: ellipsoid falloff (no box/cube outlines) */
float anchorEnvelope (vec3 p) {
  mediumCacheAnchors();
  float rho = 0.0;
  for (int i = 0; i < 16; ++i) {
    if (float(i) + 0.5 >= volCount) break;
    vec4 c = gAnchorC[i];
    vec4 d = gAnchorD[i];
    vec4 e = gAnchorE[i];

    // Normalised ellipsoid distance with C1 smoothstep falloff at plume edge
    float dist = length((p - c.xyz) / anchorExtent(c, d, e));
    if (dist >= 1.0) continue;
    float env = smoothstep(1.0, 0.0, dist);

    float n = smoothNoise(p * d.y + vec3(d.z));
    rho += d.x * env * smoothstep(0.30, 0.9, n);
  }
  return rho;
}

/* Ray-AABB section over the anchor list, as the UNION bound: the earliest entry
 * to the latest exit across all anchors, clamped to [0, tCap]. Returns a
 * zero-length interval (y <= x) when the ray misses every anchor.
 *
 * It used to fold the anchors together with min/max the other way round -- an
 * INTERSECTION of the slabs. Anchors sit on a 12k lattice and up to 16 are
 * uploaded, so that intersection is empty almost everywhere: the caller got
 * sec.y < sec.x, computed a negative step, and marched BACKWARDS from sec.x.
 * That is what produced the hard diagonal seams and white slabs in the
 * `nebula.debug = Anchors` view. Only that view consumes this function. */
vec2 cloudSection (vec3 ro, vec3 rd, float tCap) {
  if (volCount < 0.5) return vec2(0.0, tCap);

  // Scalar component checks for safe inverse calculation
  vec3 invRd;
  invRd.x = 1.0 / (abs(rd.x) < 1e-9 ? (rd.x < 0.0 ? -1e-9 : 1e-9) : rd.x);
  invRd.y = 1.0 / (abs(rd.y) < 1e-9 ? (rd.y < 0.0 ? -1e-9 : 1e-9) : rd.y);
  invRd.z = 1.0 / (abs(rd.z) < 1e-9 ? (rd.z < 0.0 ? -1e-9 : 1e-9) : rd.z);

  float tEnter = 1e30;
  float tExit = -1e30;

  mediumCacheAnchors();
  for (int i = 0; i < 16; ++i) {
    if (float(i) + 0.5 >= volCount) break;
    vec4 c = gAnchorC[i];
    vec4 d = gAnchorD[i];
    vec4 e = gAnchorE[i];
    // Must bound the ELLIPSOID, not a cube of extX, or the early-out clips the
    // stretched plumes (and marches empty space where it does not).
    vec3 bMin = c.xyz - anchorExtent(c, d, e);
    vec3 bMax = c.xyz + anchorExtent(c, d, e);

    vec3 t0 = (bMin - ro) * invRd;
    vec3 t1 = (bMax - ro) * invRd;
    vec3 tMin = min(t0, t1);
    vec3 tMax = max(t0, t1);

    float tE = max(max(tMin.x, tMin.y), tMin.z);
    float tX = min(min(tMax.x, tMax.y), tMax.z);

    if (tX > max(0.0, tE)) {
      tEnter = min(tEnter, max(0.0, tE));
      tExit = max(tExit, tX);
    }
  }
  if (tExit <= tEnter) return vec2(0.0, 0.0);
  return vec2(tEnter, min(tExit, tCap));
}

/* Total per-sample density + palette-weighted albedo */
vec4 mediumCloud (vec3 p) {
  mediumCacheAnchors();
  float rho = mediumDensity(p);
  vec3 alb = volTint * rho;

  for (int i = 0; i < 16; ++i) {
    if (float(i) + 0.5 >= volCount) break;
    vec4 c = gAnchorC[i];
    vec4 d = gAnchorD[i];
    vec4 e = gAnchorE[i];
    vec4 rim = gAnchorR[i];

    // Ellipsoid distance with smooth edge attenuation
    float dist = length((p - c.xyz) / anchorExtent(c, d, e));
    if (dist >= 1.0) continue;
    float env = smoothstep(1.0, 0.0, dist);

    float n = smoothNoise(p * d.y + vec3(d.z));
    float ri = d.x * env * smoothstep(0.30, 0.9, n);
    rho += ri;
    // Dual-tone gradient: core colour through the body, the darker rim colour
    // on the outer shell. Keyed on RADIUS, not on the envelope -- `env` is the
    // density, so mixing on it handed the rim tone most of the plume's *volume*
    // (volume goes as r^3: everything past 0.65R is 72% of it) and dimmed the
    // whole field. Out here the rim shows as a second tone but rides on density
    // that is already falling, so it costs the body almost nothing. NebulaVolumes
    // authors the rim as hsl(s, 0.65, 0.35) against a core of hsl(s, 0.80, 0.60),
    // i.e. deliberately darker.
    alb += ri * mix(e.xyz, rim.xyz, smoothstep(0.55, 0.95, dist));
  }

  vec3 finalAlb = (rho > 1e-6) ? (alb / rho) : volTint;
  return vec4(rho, finalAlb);
}

/* Full optical depth over [0, tCap] */
float mediumOpticalDepth (vec3 ro, vec3 rd, float tCap) {
  float step = tCap / max(1.0, volSteps);
  float od = 0.0;
  if (step <= 0.0) return 0.0;
  for (int i = 0; i < 48; ++i) {
    if (float(i) + 0.5 >= volSteps) break;
    od += mediumCloud(ro + rd * (float(i) + 0.5) * step).x * step;
  }
  return od;
}

#endif
