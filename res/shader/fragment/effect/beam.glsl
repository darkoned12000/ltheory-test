#include fragment
#include math
#include noise

layout(location = 0) out vec4 fragColor;
uniform vec3 color;
uniform float alpha;

void main() {
  float u = 2.0 * uv.x - 1.0;
  float v = uv.y;
  float a = 0.0;
  u = max(0.0, abs(u) - 0.01);
  a += exp(-sqrt(256.0 * u));
  a += exp(-sqrt(128.0 * u));
  a += exp(-sqrt(64.0 * u));
  a += 0.5 * exp(-sqrt(32.0 * u));
  a *= saturate(pow2(32.0 * v)) * pow8(1.0 - v);
  fragColor = vec4(a * pow2(alpha) * pow2(color), 1.0);
}
