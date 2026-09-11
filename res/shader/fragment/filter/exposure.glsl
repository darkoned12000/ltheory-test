#include filter

layout(location = 0) out vec4 fragColor;

uniform float timeSeed = 1.0;

/* Rec.709 relative luminance */
float lum (vec3 c) {
  return dot(c, vec3(0.2126, 0.7152, 0.0722));
}

/* Reversible integer hash for pseudo-random distribution */
uint Hash (uint x) {
  x ^= x >> 16;
  x *= 0x7feb352du;
  x ^= x >> 15;
  x *= 0x846ca68bu;
  x ^= x >> 16;
  return x;
}

/* One-tap exposure meter. Renders the pre-tonemap HDR scene down to a single
 * texel carrying, in the channels:
 *   R – center-weighted average luminance (whole frame)
 *   G – max sampled luminance
 *   B – fraction of samples exceeding 1.0 linear (HDR "is this range used")
 *   A – center-weighted average luminance of LIT pixels (> litFloor) — the
 *       driver for auto-exposure keying
 * The draw targets a 1x1 FBO (viewed from `size`), then the engine reads the
 * texel back once every ~100 ms (see Renderer:meter). */
void main() {
  const int N = 4096;
  uint seed = floatBitsToUint(timeSeed);
  const float litFloor = 0.0005;

  float wSum = 0.0;
  float wAvg = 0.0;
  float wLit = 0.0;
  float wLitN = 0.0;
  float maxL = 0.0;
  float over = 0.0;

  for (int i = 0; i < N; ++i) {
    uint h = Hash(uint(i) * 2654435761u + seed);
    vec2 sampleUV = vec2(
      float(h & 0xFFFFu),
      float((h >> 16) & 0xFFFFu)) * (1.0 / 65535.0);
    ivec2 px = ivec2(clamp(sampleUV * size, vec2(0.0), vec2(size) - vec2(1.0)));
    float L = lum(max(texelFetch(src, px, 0).xyz, vec3(0.0)));

    vec2 d = sampleUV - 0.5;
    float w = exp(-6.0 * dot(d, d));
    wSum += w;
    wAvg += w * L;
    if (L > litFloor) {
      wLitN += w;
      wLit  += w * L;
    }
    maxL = max(maxL, L);
    over += step(1.0, L);
  }

  fragColor = vec4(
    (wSum > 0.0)  ? wAvg / wSum  : 0.0,
    maxL,
    over / float(N),
    (wLitN > 0.0) ? wLit / wLitN : 0.0);
}
