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
uniform float     volJitter; /* ray-start jitter, in steps (0 = none) */

/* Lightning storm flash sources (fog-nebula Phase 4). Bounded 2D float table
 * mirroring texAnchors, ≤ lightningCount rows:
 *   col0 = (pos.xyz, radius)
 *   col1 = (color.rgb, energy)
 *   col2 = (spawnTime, duration, attack, 0)
 * Envelope: rise via smoothstep over `attack` then pow-decay over `duration`,
 * all against volTime (same clock the controller writes spawnTime in). The
 * flash is a radius-normalized point light: full `energy` at the strike, half
 * strength at radius/8, then a soft (1-d/radius)^2 gate to zero at the edge,
 * so the whole nearby cloud lights up instead of a tight 1/d^2 ball. It never
 * modifies T (scene*T + inscatter ordering preserved, so a bolt lights gas but
 * cannot un-occlude stars). */
uniform int       lightningCount;
uniform sampler2D texLightning;

/* Henyey-Greenstein phase (g -> 0 isotropic 1/4pi). Safe against division-by-zero. */
float hgPhase (float c) {
  float g2 = volAniso * volAniso;
  float denom = pow(max(1e-5, 1.0 + g2 - 2.0 * volAniso * c), 1.5);
  return (1.0 - g2) / (4.0 * 3.141592653589793 * denom);
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

  /* Blue-noise ray-start jitter. Fixed (i+0.5) sampling builds concentric
   * band shells around the camera that sweep while flying and read as
   * crawling waves at high density gain; one static blue-noise offset per
   * pixel turns the bands into stable fine grain instead. Reuses the GTAO
   * 64x64 LUT already bound as texNoise (sized via textureSize, no magic). */
  ivec2 bnSize = textureSize(texNoise, 0);
  ivec2 bnUV = ivec2(int(mod(gl_FragCoord.x, float(max(bnSize.x, 1)))),
                     int(mod(gl_FragCoord.y, float(max(bnSize.y, 1)))));
  float bn = texelFetch(texNoise, bnUV, 0).r;

  vec3 inscatter = vec3(0.0);
  float tr = 1.0;

  // Multiplicative tint filter (1.0, 1.0, 1.0 = neutral pass-through)
  vec3 tintFilter = mix(vec3(1.0), volTint, volTintAmt);

  for (int i = 0; i < 48; ++i) {
    if (float(i) + 0.5 >= volSteps) break;

    vec3 p = ro + rd * min((float(i) + 0.5 + (bn - 0.5) * volJitter) * step, tCap);
    vec4 mc = mediumCloud(p);
    float rho = mc.x;

    if (rho > 1e-6) {
      float ndl = dot(rd, normalize(starDir));

      // Illumination = (Sun Radiance + Ambient Skybox Starlight) * Plume Palette * Tint Filter
      //
      // Ambient starlight comes from the IR cube at a HIGH mip. LOD 0 still
      // carries bright point features (stars), and sampling it per pixel mapped
      // each one to a dot on screen -> dots landed on planets ("light shining
      // through the planet"). A blurred LOD gives a smooth ambient instead.
      // (GenIRMap mipmaps, so this is well-defined.)
      vec3 ambient = textureLod(irMap, rd, 6.0).xyz;
      vec3 light = (sunColor * hgPhase(ndl) + ambient) * mc.yzw * tintFilter;
      // Also bound the per-sample radiance so no direction can spike.
      light = min(light, vec3(3.0));

      /* Lightning storm flash — bounded point-light loop (≤6, no branch on count) */
      for (int L = 0; L < 6; ++L) {
        if (float(L) + 0.5 >= float(lightningCount)) break;
        vec4 lp = texelFetch(texLightning, ivec2(0, L), 0); /* pos.xyz, radius */
        float dL = length(p - lp.xyz);
        if (dL >= lp.w) continue;                            /* radius cull */
        vec4 lc = texelFetch(texLightning, ivec2(1, L), 0); /* color, energy */
        vec4 lt = texelFetch(texLightning, ivec2(2, L), 0); /* spawnTime, duration, attack */
        float age = volTime - lt.x;
        if (age < 0.0 || age > lt.y) continue;
        float flash = smoothstep(0.0, max(1e-4, lt.z), age)
                    * pow(clamp(1.0 - age / lt.y, 0.0, 1.0), 2.0);
        /* Re-strike shimmer: real bolts re-strike instead of fading smoothly.
         * Same flicker the UI ribbon/glow use so both halves agree. */
        flash *= 0.72 + 0.28 * sin(age * 43.0) * sin(age * 17.0 + 1.3);
        /* Radius-normalized falloff: peak `energy` at the strike, ~half at
         * radius/8, soft-gated to zero at the edge (cloud-scale glow, no ball
         * edge pop against the `dL >= radius` reject above). */
        float norm = dL / max(1.0, lp.w);
        float soft = clamp(1.0 - norm, 0.0, 1.0);
        soft *= soft;
        float att = (lc.w * flash) / (norm * norm * 64.0 + 1.0) * soft * exp(-dL * volSigmaT);
        light += lc.rgb * att;
      }

      float stepTr = exp(-volSigmaT * rho * step);
      inscatter += tr * (1.0 - stepTr) * (volSigmaS / max(1e-6, volSigmaT)) * light;
      tr *= stepTr;
    }
  }

  fragData0 = vec4(max(inscatter, vec3(0.0)), clamp(tr, 0.0, 1.0));
}
