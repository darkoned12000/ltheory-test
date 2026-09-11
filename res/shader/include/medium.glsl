#ifndef include_medium
#define include_medium

/* Volumetric medium — fog-nebula-implementation.md.
 * Shared by filter/volume.glsl (half-res layer) and filter/volblur.glsl
 * (full-res composite + debug views).
 */
#include math
#include noise

uniform float volDensity;    /* medium master gain                       */
uniform float volSigmaT;     /* extinction per unit optical depth        */
uniform float volSigmaS;     /* scattering per unit optical depth        */
uniform float volSteps;      /* raymarch step budget (float, 8/16/24)   */
uniform float volDist;       /* max march distance, world units          */
uniform float volMip;        /* log2(fullres / halfres)                  */
uniform float volEvals;      /* noise-eval budget: 2 (Q1/Q2) or 3 (Q3)  */
uniform vec3  volFlow;       /* deterministic world drift, u/s           */
uniform float volTime;       /* seconds                                  */
uniform float volCount;      /* active anchors (bounded, CPU-culled)     */
uniform vec3  volTint;       /* background albedo                        */
uniform float volTintAmt;    /* background tint mix                      */
uniform sampler2D texAnchors;/* RGBA32F rows per anchor                  */

/* Background banks (world-space) */
float mediumDensity (vec3 p) {
  p += volFlow * volTime;
  float a = valueNoise(p * 0.0004);
  float b = valueNoise(p * 0.002);
  float d = smoothstep(0.42, 0.62, 0.66 * a + 0.34 * b);
  if (volEvals >= 2.5) {
    float m = valueNoise(p * 0.0016 + b * 3.0);
    d *= smoothstep(0.35, 0.8, m);
  }
  return volDensity * d;
}

/* Anchor plumes: smooth spherical falloff to prevent box/cube outlines */
float anchorEnvelope (vec3 p) {
  float rho = 0.0;
  for (int i = 0; i < 16; ++i) {
    if (float(i) + 0.5 >= volCount) break;
    vec4 c = texelFetch(texAnchors, ivec2(0, i), 0);
    vec4 d = texelFetch(texAnchors, ivec2(1, i), 0);

    // Spherical distance with C1 smoothstep falloff at plume edge
    float dist = length(p - c.xyz) / max(c.w, 1e-4);
    if (dist >= 1.0) continue;
    float env = smoothstep(1.0, 0.0, dist);

    float n = valueNoise(p * d.y + vec3(d.z));
    rho += d.x * env * smoothstep(0.45, 0.8, n);
  }
  return rho;
}

/* Ray-AABB section over the anchor list with robust slab intersection */
vec2 cloudSection (vec3 ro, vec3 rd, float tCap) {
  vec2 sec = vec2(0.0, tCap);
  if (volCount < 0.5) return sec;

  // Scalar component checks for safe inverse calculation
  vec3 invRd;
  invRd.x = 1.0 / (abs(rd.x) < 1e-9 ? (rd.x < 0.0 ? -1e-9 : 1e-9) : rd.x);
  invRd.y = 1.0 / (abs(rd.y) < 1e-9 ? (rd.y < 0.0 ? -1e-9 : 1e-9) : rd.y);
  invRd.z = 1.0 / (abs(rd.z) < 1e-9 ? (rd.z < 0.0 ? -1e-9 : 1e-9) : rd.z);

  for (int i = 0; i < 16; ++i) {
    if (float(i) + 0.5 >= volCount) break;
    vec4 c = texelFetch(texAnchors, ivec2(0, i), 0);
    vec3 bMin = c.xyz - vec3(c.w);
    vec3 bMax = c.xyz + vec3(c.w);

    vec3 t0 = (bMin - ro) * invRd;
    vec3 t1 = (bMax - ro) * invRd;
    vec3 tMin = min(t0, t1);
    vec3 tMax = max(t0, t1);

    float tE = max(max(tMin.x, tMin.y), tMin.z);
    float tX = min(min(tMax.x, tMax.y), tMax.z);

    if (tX > max(0.0, tE)) {
      sec.x = (sec.x == 0.0) ? max(0.0, tE) : min(sec.x, max(0.0, tE));
      sec.y = min(sec.y, tX);
    }
  }
  return sec;
}

/* Total per-sample density + palette-weighted albedo */
vec4 mediumCloud (vec3 p) {
  float rho = mediumDensity(p);
  vec3 alb = volTint * rho;

  for (int i = 0; i < 16; ++i) {
    if (float(i) + 0.5 >= volCount) break;
    vec4 c = texelFetch(texAnchors, ivec2(0, i), 0);
    vec4 d = texelFetch(texAnchors, ivec2(1, i), 0);

    // Spherical distance with smooth edge attenuation
    float dist = length(p - c.xyz) / max(c.w, 1e-4);
    if (dist >= 1.0) continue;
    float env = smoothstep(1.0, 0.0, dist);

    float n = valueNoise(p * d.y + vec3(d.z));
    float ri = d.x * env * smoothstep(0.45, 0.8, n);
    rho += ri;
    alb += ri * texelFetch(texAnchors, ivec2(2, i), 0).xyz;
  }

  vec3 finalAlb = (rho > 1e-6) ? (alb / rho) : volTint;
  return vec4(rho, finalAlb);
}

/* Full optical depth over [0, tCap] */
float mediumOpticalDepth (vec3 ro, vec3 rd, float tCap) {
  float step = tCap / max(1.0, volSteps);
  float od = 0.0;
  if (step <= 0.0) return 0.0;
  for (int i = 0; i < 24; ++i) {
    if (float(i) + 0.5 >= volSteps) break;
    od += mediumCloud(ro + rd * (float(i) + 0.5) * step).x * step;
  }
  return od;
}

#endif
