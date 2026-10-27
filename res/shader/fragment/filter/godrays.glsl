#include fragment
#include deferred
#include medium

/* God-ray shaft pass, quarter-res worldray — fog-nebula Phase 3.
 * An INDEPENDENT low-res march that accumulates only the sun's forward
 * scatter along each camera ray (tight Henyey-Greenstein lobe `godA`), so
 * bright anisotropic shafts bloom around the star while the base Nebula
 * layer keeps its own tuning. Outputs:
 *   rgb = shaft radiance   (sunColor * P(godA) * albedo, integrated *T)
 *   a   = log2(linear eye depth), consumed by godblur's bilateral gather.
 *
 * NOTE on the alpha: the same T is ALREADY folded into `shaft.rgb` by the
 * `tr *= stepTr` accumulation before each sample, so the composite must NOT
 * multiply by it again (that would double-occlude). It is written for parity
 * This depth key is required by godblur: without it the quarter-res shaft
 * image is radially gathered across foreground silhouettes, painting a
 * ghostly "shadow" of ships/rocks over the scene.
 *
 * Sky gate and depth behaviour mirror volume.glsl so geometry occludes
 * shafts naturally (tCap stops at the first surface).
 */

in vec3 worldOrigin;
in vec3 worldDir;

uniform sampler2D texDepth;  /* zBufferL (linear eye distance) */
uniform vec3      sunColor;  /* sun radiance                   */
uniform float     godA;      /* shaft HG phase g (forward lobe) */

/* Henyey-Greenstein phase (g -> 0 isotropic 1/4pi). Safe against div-by-zero. */
float hgPhase (float c) {
  float g2 = godA * godA;
  float denom = pow(max(1e-5, 1.0 + g2 - 2.0 * godA * c), 1.5);
  return (1.0 - g2) / (4.0 * 3.141592653589793 * denom);
}

void main () {
  vec3 ro = worldOrigin;
  vec3 rd = normalize(worldDir);

  /* Use a point depth at this shaft texel. Linear-filtering the full-res
   * depth at a quarter-res fragment averages foreground geometry with sky,
   * producing a fictitious mid-distance march length at silhouettes. */
  ivec2 depthSize = textureSize(texDepth, 0);
  ivec2 depthPixel = clamp(ivec2(uv * vec2(depthSize)), ivec2(0), depthSize - 1);
  float dist = texelFetch(texDepth, depthPixel, 0).r;
  if (dist < 1e-4) {
    /* Alpha carries log2(eyeDepth) for godblur's depth-aware radial gather. */
    fragData0 = vec4(0.0, 0.0, 0.0, log2(1.0e6));
    return;
  }

  bool isSky = dist >= 900000.0;
  float tCap = isSky ? volDist : min(dist, volDist);
  float step = tCap / max(1.0, volSteps);

  vec3 sun = normalize(starDir);
  vec3 shaft = vec3(0.0);
  float tr = 1.0;

  for (int i = 0; i < 24; ++i) {
    if (float(i) + 0.5 >= volSteps) break;

    vec3 p = ro + rd * (float(i) + 0.5) * step;
    vec4 mc = mediumCloud(p);
    float rho = mc.x;

    if (rho > 1e-6) {
      float ndl = dot(rd, sun);
      float stepTr = exp(-volSigmaT * rho * step);
      shaft += tr * (1.0 - stepTr) * (volSigmaS / max(1e-6, volSigmaT))
             * mc.yzw * sunColor * hgPhase(ndl);
      tr *= stepTr;
    }
  }

  /* Alpha is unused by the composite; store log-depth so the full-res radial
   * blur can reject taps from behind foreground geometry. */
  fragData0 = vec4(max(shaft, vec3(0.0)), log2(max(dist, 1.0)));
}
