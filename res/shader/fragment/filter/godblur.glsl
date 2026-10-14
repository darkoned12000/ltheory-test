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

uniform sampler2D texVol;    /* godView, shaft buffer (quarter-res)   */
uniform sampler2D texScene;  /* lit scene at this point (full-res)    */
uniform sampler2D texNoise;  /* 64x64 blue-noise LUT (crawl dither)   */
uniform vec2      sunUV;     /* sun screen uv, normalized [0..1]      */
uniform float     godStrength;
uniform float     godCeiling; /* soft ceiling on the added shaft (0 = linear) */
uniform int       godMode;   /* 0 composite, 1 debug                  */

void main () {
  vec2 toSun = sunUV - uv;
  float d = length(toSun) + 1e-5;
  vec2 dir = toSun / d;

  const int N = 8;                          /* weights decay 2^-2i: taps 7+ < 0.4% */
  vec3 acc = vec3(0.0);
  float wsum = 0.0;
  float t0 = texture(texNoise, uv).x * (1.0 / float(N));  /* sub-tap dither */
  for (int i = 0; i < N; ++i) {
    float t = t0 + float(i) / float(N);     /* 0..~1, crawl toward the sun */
    vec2 sp = uv + dir * d * t;             /* crawl toward the sun */
    vec3 v = texture(texVol, sp).rgb;
    float w = exp2(-2.0 * float(i));        /* near-sun taps dominate */
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