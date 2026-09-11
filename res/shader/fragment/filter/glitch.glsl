#include fragment
#include noise

layout(location = 0) out vec4 fragColor;

uniform sampler2D src;
uniform vec2 size;
uniform float strength;
uniform float scroll;

void main() {
  vec4 c1 = texture(src, uv);
  vec2 p = size * uv;
  p.x += scroll;

  // Clamp noise value to prevent log(<= 0.0) NaN crashes
  float noiseVal = clamp(valueNoise(p / 2.0), 0.0, 1.0);
  float mag = -0.4 * log(max(1e-5, 1.001 - pow(noiseVal, 4.0)));
  float sgn = 2.0 * valueNoise(p.x / 2.0) - 1.0;
  float dv = sgn * mag;

  vec4 c2 = texture(src, uv + vec2(0.0, dv));

  // Guard HDR color values against negative exponentiation
  c2.xyz = pow(max(c2.xyz, vec3(0.0)), vec3(1.2, 1.1, 0.6));
  fragColor = max(c1, strength * c2);
}
