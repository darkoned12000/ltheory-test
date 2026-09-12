#include fragment
#include color
#include math

layout(location = 0) out vec4 fragColor;
uniform vec3 color;
uniform float alpha;

void main() {
  float r = length(uv);
  float a = 0.0;
  a += exp(-sqrt(256.0 * r));
  a += exp(-sqrt(128.0 * r));
  a *= 4.0;
  vec3 c = color;
  c *= c / max(avg(c), 1e-5);
  fragColor = vec4(a * alpha * c, 1.0);
  FRAGMENT_CORRECT_DEPTH;
}
