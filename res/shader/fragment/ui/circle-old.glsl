#include fragment
#include math

layout(location = 0) out vec4 fragColor;
uniform vec4 color;
uniform vec2 size;
uniform float radius;

void main() {
  vec2 safeSize = max(vec2(1e-4), size);
  float r = length(safeSize * (uv - 0.5));
  float d = max(0.0, r / safeSize.x);

  float alpha = 0.0;
  alpha += 2.0 * exp(-pow2(64.0 * d));
  alpha += 1.0 * exp(-pow(max(1e-5, 32.0 * d), 0.75));

  vec4 c = alpha * color.w * vec4(2.0 * color.xyz, 1.0);
  if (isnan(c.r) || isnan(c.g) || isnan(c.b) || isnan(c.a)) {
    c = vec4(0.0);
  }

  fragColor = c;
}
