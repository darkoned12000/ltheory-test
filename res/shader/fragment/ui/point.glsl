#include fragment
#include math

layout(location = 0) out vec4 fragColor;
uniform vec4 color;

const float scale = 1.0;

void main() {
  vec2 uvp = 2.0 * uv - vec2(1.0, 1.0);
  float r = scale * length(uvp);
  float alpha = 0.0;
  alpha += exp(-258.0 * max(0.0, r - 0.01));
  alpha += 0.1 * exp(-pow(max(1e-5, 8.0 * r), 0.75));
  vec3 c = 2.0 * color.xyz;
  vec4 outCol = alpha * color.w * vec4(c, 1.0);

  if (isnan(outCol.r) || isnan(outCol.g) || isnan(outCol.b) || isnan(outCol.a)) {
    outCol = vec4(0.0);
  }

  fragColor = max(vec4(0.0), outCol);
}
