// Clamps strength and scanline multipliers, guards texture inputs against negative components,
// and standardizes scanline frequency calculations to avoid moiré patterns.

#include filter
#include math
#include color
#include noise

layout(location = 0) out vec4 fragColor;

uniform float strength;
uniform float scanlines;

const float k = 1.0;
const float a = 0.005;

void main() {
  vec3 cc = max(texture(src, uv).xyz, vec3(0.0));
  vec3 c = cc;

  vec3 tw = vec3(1.0);
  float w = 1.0;
  vec2 dir = (uv - 0.5);
  dir *= k;
  dir = sign(dir) * pow2(dir);
  dir /= k;

  vec2 uvp = uv;
  for (int i = 0; i < 32; ++i) {
    w *= 0.9;
    uvp += a * dir;
    c += w * max(texture(src, uvp).xyz, vec3(0.0));
    tw += w;
  }
  c /= tw;

  float r = length(2.0 * uv - 1.0);
  float f2 = 1.0 - exp(-r);

  // Moiré-resistant scanline modulation
  float scanlinePattern = sin(gl_FragCoord.y * 3.14159265);
  vec3 crtColor = c * (1.0 + f2 * vec3(0.5, 0.2, 0.1) * scanlinePattern);

  c = mix(c, crtColor, clamp(scanlines, 0.0, 1.0));
  c = mix(cc, c, clamp(strength, 0.0, 1.0));

  fragColor = vec4(max(c, vec3(0.0)), 1.0);
}
