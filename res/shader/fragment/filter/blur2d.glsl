#include filter

layout(location = 0) out vec4 fragColor;

uniform int radius;
uniform float sigma;

void main() {
  vec4 c = vec4(0.0);
  float tw = 0.0;
  float sig2 = max(sigma * sigma, 1e-5);

  for (int y = -radius; y <= radius; ++y) {
    for (int x = -radius; x <= radius; ++x) {
      vec2 offset = vec2(float(x), float(y));
      float w = exp(-dot(offset, offset) / sig2);
      c += w * texture(src, uv + offset / size);
      tw += w;
    }
  }

  fragColor = c / max(tw, 1e-5);
}
