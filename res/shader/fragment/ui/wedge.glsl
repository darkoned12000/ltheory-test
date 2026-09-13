#include fragment
#include math

layout(location = 0) out vec4 fragColor;
uniform vec2 size;
uniform vec4 color;
uniform float r1;
uniform float r2;
uniform float to;
uniform float tw;

const float bevel = 2.0;

void main() {
  float Tau = radians(360.0);
  vec2 safeSize = max(vec2(1e-4), size);
  vec2 p = safeSize * (uv - 0.5);
  float r = length(p);
  vec2 dir = vec2(cos(Tau * to), sin(Tau * to));
  float rd = abs(r - 0.5 * (r1 + r2)) - 0.5 * (r2 - r1);

  vec2 centerVec = vec2(uv.x, 1.0 - uv.y) - 0.5;
  float lenCenter = length(centerVec);
  vec2 normCenter = (lenCenter > 1e-6) ? (centerVec / lenCenter) : vec2(1.0, 0.0);

  float dotVal = clamp(dot(dir, normCenter), -1.0, 1.0);
  float td = 0.5 * safeSize.x * (acos(dotVal) - 0.5 * Tau * tw);
  float d = max(0.0, length(max(vec2(0.0), vec2(rd, td) + bevel)) - bevel);

  float alpha = 0.0;
  alpha += 0.5 * exp(-max(0.0, d - 0.5));
  alpha += 0.4 * exp(-pow(max(1e-5, 0.3 * d), 0.75));
  vec3 c = 2.0 * color.xyz;
  vec4 outCol = alpha * color.w * vec4(c, 1.0);

  if (isnan(outCol.r) || isnan(outCol.g) || isnan(outCol.b) || isnan(outCol.a)) {
    outCol = vec4(0.0);
  }

  fragColor = max(vec4(0.0), outCol);
}
