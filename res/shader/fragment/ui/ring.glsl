#include fragment

layout(location = 0) out vec4 fragColor;
flat in vec4 color;
flat in vec4 widget_a;

void main() {
  float radius = widget_a.x;
  vec2 safeSize = max(vec2(1e-4), widget_a.yz);
  vec2 uvp = uv - 0.5;
  float r = length(safeSize * uvp);
  float alpha = 0.0;
  float d = abs(r - radius);
  alpha += 0.5 * exp(-max(0.0, d - 0.5));
  alpha += 0.4 * exp(-pow(max(1e-5, 0.2 * d), 0.75));
  vec3 c = 2.0 * color.xyz;
  vec4 outCol = alpha * color.w * vec4(c.xyz, 1.0);

  if (isnan(outCol.r) || isnan(outCol.g) || isnan(outCol.b) || isnan(outCol.a)) {
    outCol = vec4(0.0);
  }

  fragColor = max(vec4(0.0), outCol);
}
