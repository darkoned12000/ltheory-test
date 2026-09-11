#include fragment
#include deferred
#include math
#include noise
#include medium

/* Volumetric layer, pass A (half-res, worldray) — fog-nebula Phase 2.
 * Outputs one RGBA16F "volView" texel per half-res pixel:
 *   rgb = inscatter   (single-scatter, summed against transmittance)
 *   a   = transmittance T = exp(-sigma_t * opticalDepth)
 * The medium contract lives in include/medium.glsl.
 */

in vec3 worldOrigin;
in vec3 worldDir;

uniform sampler2D texDepth;  /* zBufferL (linear eye distance) */
uniform sampler2D texNoise;  /* 64x64 blue-noise LUT */
uniform vec3      sunColor;  /* sun radiance */
uniform float     volAniso;  /* Henyey-Greenstein g (-1..1) */

/* Henyey-Greenstein phase (g -> 0 isotropic 1/4pi). */
float hgPhase (float c) {
  float g2 = volAniso * volAniso;
  return (1.0 - g2) / (4.0 * 3.141592653589793 * pow(1.0 + g2 - 2.0 * volAniso * c, 1.5));
}

void main () {
  vec3 ro = worldOrigin;
  vec3 rd = normalize(worldDir);

  float dist = textureLod(texDepth, uv, 0.0).r;

  if (dist < 1e-4) {
    fragData0 = vec4(0.0, 0.0, 0.0, 1.0);
    return;
  }

  bool isSky = dist >= 900000.0;
  float tCap = isSky ? volDist : min(dist, volDist);
  float step = tCap / max(1.0, volSteps);

  vec3 inscatter = vec3(0.0);
  float tr = 1.0;

  // Multiplicative tint filter (1.0, 1.0, 1.0 = neutral pass-through)
  vec3 tintFilter = mix(vec3(1.0), volTint, volTintAmt);

  for (int i = 0; i < 24; ++i) {
    if (float(i) + 0.5 >= volSteps) break;

    vec3 p = ro + rd * (float(i) + 0.5) * step;
    vec4 mc = mediumCloud(p);
    float rho = mc.x;

    if (rho > 1e-6) {
      float ndl = dot(rd, normalize(starDir));

      // Illumination = (Sun Radiance + Ambient Skybox Starlight) * Plume Palette * Tint Filter
      vec3 light = (sunColor * hgPhase(ndl) + texture(irMap, rd).xyz) * mc.yzw * tintFilter;

      float stepTr = exp(-volSigmaT * rho * step);
      inscatter += tr * (1.0 - stepTr) * (volSigmaS / max(1e-6, volSigmaT)) * light;
      tr *= stepTr;
    }
  }

  fragData0 = vec4(inscatter, tr);
}
