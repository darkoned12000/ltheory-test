#include filter

layout(location = 0) out vec4 fragColor;

uniform vec2 dir;
uniform int radius;
uniform float variance;

/* Half-tap Gaussian: adjacent integer-distance tap pairs are merged into ONE
 * bilinear fetch placed at their weighted center, so the hardware filter does
 * the pair sum for free. Fetches drop from `radius` to ceil(radius/2) per
 * side. Output matches the naive loop up to float precision. Requires LINEAR
 * filtering on src (true for all renderer buffers).
 *
 * NOTE : textureGather was evaluated here first and rejected -- symmetric
 * Gaussian taps never share a 1-texel-wide gather quad, and these are RGBA
 * buffers (one gather call covers a single component). See opt-texgather
 * branch notes; gather becomes interesting for future depth/shadow passes. */

void main() {
  float v = max(variance * variance, 1e-5);
  vec2 stepPx = dir / size;
  vec4 total = texture(src, uv);
  float tw = 1.0;

  for (int i = 1; i <= radius; i += 2) {
    float fi = float(i);
    float w1 = exp(-(fi * fi) / v);
    if (i + 1 <= radius) {
      float fj = fi + 1.0;
      float w2 = exp(-(fj * fj) / v);
      float s = w1 + w2;
      float sSafe = max(s, 1e-8);
      vec2 off = (fi + w2 / sSafe) * stepPx;
      total += s * texture(src, uv + off);
      total += s * texture(src, uv - off);
      tw += 2.0 * s;
    } else {
      vec2 delta = fi * stepPx;
      total += w1 * texture(src, uv + delta);
      total += w1 * texture(src, uv - delta);
      tw += 2.0 * w1;
    }
  }

  fragColor = total / max(tw, 1e-5);
}
