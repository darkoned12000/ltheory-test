#include fragment
#include deferred
#include math

/* God-ray screen-space integrator + scene composite — fog-nebula Phase 3.
 * Crawls each pixel toward the sun's screen uv, stroking weighted taps of
 * the quarter-res shaft buffer (godrays.glsl) along the way, so the whole
 * shaft pulls into visible streaks radiating from the star. The crawl start
 * is dithered with blue noise (texNoise, GTAO discipline) so the fixed
 * radial path can't show concentric stepping near the sun.
 *
 *   mode 0 composite   scene + shaft * strength
 *   mode 1 debug       shaft only (×8 so it shows pre-tonemap)
 */

uniform sampler2D texVol;    /* godView, shaft + log-depth (quarter-res) */
uniform sampler2D texScene;  /* lit scene at this point (full-res)       */
uniform sampler2D texDepth;  /* full-res linear eye depth                */
uniform sampler2D texNoise;  /* 64x64 blue-noise LUT (crawl dither)   */
uniform vec2      sunUV;     /* sun screen uv, normalized [0..1]      */
uniform float     godStrength;
uniform float     godCeiling; /* soft ceiling on the added shaft (0 = linear) */
uniform int       godMode;   /* 0 composite, 1 debug                  */

/* Bilateral upsample: manually gather the quarter-res shaft texels around
 * uv, weighting by bilinear footprint AND agreement with the full-res
 * receiver depth. Never use a plain texture() fallback at silhouettes: that
 * can bleed bright background shafts across foreground geometry. */
vec3 sampleShaftDepthAware (vec2 sampleUv, float receiverLogDepth) {
  ivec2 size = textureSize(texVol, 0);
  vec2 p = sampleUv * vec2(size) - 0.5;
  ivec2 base = ivec2(floor(p));
  vec2 f = fract(p);
  vec3 sum = vec3(0.0);
  float spatialWeightSum = 0.0;

  for (int j = 0; j < 2; ++j) {
    for (int i = 0; i < 2; ++i) {
      ivec2 o = ivec2(i, j);
      ivec2 q = clamp(base + o, ivec2(0), size - 1);
      vec4 tap = texelFetch(texVol, q, 0);
      float bilinear = (i == 0 ? 1.0 - f.x : f.x)
                     * (j == 0 ? 1.0 - f.y : f.y);
      float depthDelta = abs(tap.a - receiverLogDepth);
      float gatedDelta = max(0.0, depthDelta - 0.08);
      float w = bilinear * exp(-4.0 * gatedDelta * gatedDelta);
      sum += tap.rgb * w;
      /* Normalize only the spatial footprint, NOT the depth weights. If all
       * taps disagree in depth, preserving their small weights suppresses
       * the leak instead of renormalizing a rejected shaft back to full power. */
      spatialWeightSum += bilinear;
    }
  }

  return sum / max(1e-6, spatialWeightSum);
}

void main () {
  vec2 toSun = sunUV - uv;
  float d = length(toSun) + 1e-5;
  vec2 dir = toSun / d;

  const int N = 8;                          /* weights decay 2^-2i: taps 7+ < 0.4% */
  vec3 acc = vec3(0.0);
  float wsum = 0.0;
  ivec2 depthSize = textureSize(texDepth, 0);
  ivec2 depthPixel = clamp(ivec2(gl_FragCoord.xy), ivec2(0), depthSize - 1);
  float centerDepth = texelFetch(texDepth, depthPixel, 0).r;
  float centerLogDepth = log2(max(centerDepth, 1.0));
  float t0 = texture(texNoise, uv).x * (1.0 / float(N));  /* sub-tap dither */
  for (int i = 0; i < N; ++i) {
    float t = t0 + float(i) / float(N);     /* 0..~1, crawl toward the sun */
    vec2 sp = uv + dir * d * t;             /* crawl toward the sun */
    /* Depth-aware upsample each radial tap at this receiver's depth. Keep
     * radial weights independent from depth rejection: dividing by a sum of
     * depth-gated weights would restore rejected shafts to full strength. */
    vec3 v = sampleShaftDepthAware(sp, centerLogDepth);
    float w = exp2(-2.0 * float(i)); /* near-sun taps dominate */
    acc += v * w;
    wsum += w;
  }
  acc /= max(1e-6, wsum);

  if (godMode == 1) {
    fragData0 = vec4(max(acc * 8.0, vec3(0.0)), 1.0);
    return;
  }

  // Soft ceiling on the additive shafts. They used to be added LINEARLY at
  // godStrength (default 8), so any pixel looking toward the star through the
  // medium went straight past 1.0 and clipped to a flat white disc -- which read
  // as a light source sitting on the planet's limb rather than as haze. A
  // Reinhard-style knee is a no-op well below the ceiling and saturates smoothly
  // above it, so no gain setting can produce a hard blob. 0 disables it.
  vec3 shaft = acc * godStrength;
  if (godCeiling > 0.0) {
    shaft = shaft / (1.0 + shaft / godCeiling);
  }
  vec3 scene = texture(texScene, uv).xyz;
  fragData0 = vec4(scene + shaft, 1.0);
}
