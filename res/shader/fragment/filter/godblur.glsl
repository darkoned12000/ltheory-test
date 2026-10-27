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
 * receiver depth.
 *
 * The gate is ASYMMETRIC. Light behind the receiver (tap logical depth
 * greater than the receiver's) must be rejected, or it leaks shafts through
 * foreground silhouettes. Light in front of the receiver (a closer occluder's
 * texel, or the truncated march its side of the silhouette) is legitimate —
 * it is scatter between the camera and the receiver — so those taps keep
 * full weight and the occluder boundary becomes a soft feather instead of
 * a hard binary cut in the glow.
 *
 * smallOccluderFallback: rocks narrower than a quarter-res texel own no texel
 * whose depth agrees with the receiver, so a strict gate zeroes their glow
 * and leaves a dark cut-out ringed by clamped-bright sky — the residual
 * edge highlight. When EVERY tap is >=4x farther than the receiver, fall
 * back to the plain bilinear blend: the glow wraps the tiny occluder the
 * way bloom already does. Radial taps pass false, so large silhouettes keep
 * their occlusion while their gathered streaks still land behind them. */
vec3 sampleShaftDepthAware (vec2 sampleUv, float receiverLogDepth, bool smallOccluderFallback) {
  ivec2 size = textureSize(texVol, 0);
  vec2 p = sampleUv * vec2(size) - 0.5;
  ivec2 base = ivec2(floor(p));
  vec2 f = fract(p);
  vec3 gatedSum = vec3(0.0);
  vec3 plainSum = vec3(0.0);
  float spatialWeightSum = 0.0;
  float minTapLog = 1e20;

  for (int j = 0; j < 2; ++j) {
    for (int i = 0; i < 2; ++i) {
      ivec2 o = ivec2(i, j);
      ivec2 q = clamp(base + o, ivec2(0), size - 1);
      vec4 tap = texelFetch(texVol, q, 0);
      float bilinear = (i == 0 ? 1.0 - f.x : f.x)
                     * (j == 0 ? 1.0 - f.y : f.y);
      plainSum += tap.rgb * bilinear;
      minTapLog = min(minTapLog, tap.a);
      /* Only taps FARTHER than the receiver are occluded light. Normalize by
       * the spatial footprint, not the depth weights: preserving the small
       * weights of rejected taps suppresses the leak instead of renormalizing
       * a rejected shaft back to full power. */
      float behind = max(0.0, tap.a - receiverLogDepth - 0.08);
      float w = bilinear * exp(-4.0 * behind * behind);
      gatedSum += tap.rgb * w;
      spatialWeightSum += bilinear;
    }
  }

  /* Quarter-res support too coarse to see this occluder at all: every tap
   * disagrees (much farther). Wrap it smoothly rather than cutting it out. */
  if (smallOccluderFallback && receiverLogDepth + 2.0 < minTapLog) {
    return plainSum / max(1e-6, spatialWeightSum);
  }
  return gatedSum / max(1e-6, spatialWeightSum);
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
     * depth-gated weights would restore rejected shafts to full strength.
     * Only the center tap may take the small-occluder wrap so structures
     * finer than the quarter-res grid still receive a smooth glow; the
     * distant crawl taps keep strict occlusion. */
    vec3 v = sampleShaftDepthAware(sp, centerLogDepth, i == 0);
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
