#include fragment
#include math

layout(location = 0) out vec4 fragColor;
uniform float padding;
uniform vec2 size;
uniform vec4 color;

const float bevel = 8.0;

float dbox(vec2 p, vec2 s, float b) {
  return length(max(vec2(0.0, 0.0), abs(p) - (s - 2.0 * vec2(b, b)))) - b;
}

void main() {
  vec2 safeSize = max(vec2(1e-4), size);
  float x = safeSize.x * (2.0 * uv.x - 1.0);
  float y = safeSize.y * (2.0 * uv.y - 1.0);

  float d = dbox(vec2(x, y), safeSize + bevel - 2.0 * padding, bevel);
  float safeD = max(0.0, d);
  float k = exp(-safeD);
  float alpha = 1.0;
  alpha *= saturate(exp(-pow(max(1e-5, 0.2 * safeD), 0.75)) - k);

  vec3 c = 2.0 * color.xyz;
  vec4 outCol = alpha * color.w * vec4(c, 1.0);

  if (isnan(outCol.r) || isnan(outCol.g) || isnan(outCol.b) || isnan(outCol.a)) {
    outCol = vec4(0.0);
  }

  fragColor = max(vec4(0.0), outCol);
}
