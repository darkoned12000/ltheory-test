#include fragment
#include math

layout(location = 0) out vec4 fragColor;
uniform float radius;
uniform float padding;
uniform float alpha;
uniform float innerAlpha;
uniform vec2 size;

float roundBox(vec2 p, vec2 s, float b) {
  return length(max(vec2(0.0, 0.0), abs(p) - (s - 2.0 * vec2(b, b)))) - b;
}

void main() {
  vec2 safeSize = max(vec2(1e-4), size);
  vec2 p = safeSize * (2.0 * uv - vec2(1.0));
  float d = roundBox(p, safeSize + vec2(radius) - 2.0 * padding, radius);
  float a = (d < 0.0) ? innerAlpha : alpha;
  vec3 c = vec3(0.01);
  a *= exp(-pow2(0.015 * max(0.0, d)));
  vec4 outCol = vec4(c, a);

  if (isnan(outCol.r) || isnan(outCol.g) || isnan(outCol.b) || isnan(outCol.a)) {
    outCol = vec4(0.0);
  }

  fragColor = max(vec4(0.0), outCol);
}
