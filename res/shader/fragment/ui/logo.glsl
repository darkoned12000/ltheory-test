#include fragment
#include noise
#include color

layout(location = 0) out vec4 fragColor;
uniform sampler2D src;
uniform vec2 size;
uniform float alpha;
uniform float strength;
uniform float scroll;

void main() {
  vec4 c1 = texture(src, uv);
  vec2 p = max(vec2(1e-4), size) * uv;
  p.x += scroll;

  float nVal = clamp(valueNoise(p / vec2(2.0)), 0.0, 1.0);
  float mag = -0.4 * log(max(1e-5, 1.001 - pow(nVal, 6.0)));

  p.x += scroll;
  float sgn = 2.0 * valueNoise(p.x / 2.0) - 1.0;
  float dv = sgn * mag;
  vec4 c2 = texture(src, uv + vec2(0, dv));

  vec3 safeC2 = max(vec3(0.0), c2.xyz);
  safeC2 = pow(safeC2, vec3(1.2, 1.1, 0.6));
  vec4 c = max(c1, strength * vec4(safeC2, c2.w));

  float a = 1.0;
  a *= 1.0 - exp(-6.0 * abs(1.0 - abs(2.0 * uv.y - 1.0)));

  vec4 outCol = vec4(c.xyz, a * alpha);
  if (isnan(outCol.r) || isnan(outCol.g) || isnan(outCol.b) || isnan(outCol.a)) {
    outCol = vec4(0.0);
  }

  fragColor = max(vec4(0.0), outCol);
}
