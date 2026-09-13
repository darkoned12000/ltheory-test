#include fragment

layout(location = 0) out vec4 fragColor;
uniform float radius;
uniform vec2 size;
uniform vec4 color;

const float k = sqrt(3.0) / 2.0;

void main() {
  vec2 uvp = uv - 0.5;
  uvp = abs(size * uvp);
  float alpha = 0.0;
  float d = max(uvp.x * k + 0.5 * uvp.y, uvp.y) - radius;
  d = max(0.0, d);
  alpha += 0.5 * exp(-max(0.0, d - 0.5));
  alpha += 0.3 * exp(-pow(max(1e-5, 0.2 * d), 0.75));
  vec3 c = 2.0 * color.xyz;
  vec4 outCol = alpha * color.w * vec4(c.xyz, 1.0);

  if (isnan(outCol.r) || isnan(outCol.g) || isnan(outCol.b) || isnan(outCol.a)) {
    outCol = vec4(0.0);
  }

  fragColor = outCol;
}
