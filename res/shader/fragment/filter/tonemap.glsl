#include filter
#include color
#include math
#include noise
#include tonemapping

layout(location = 0) out vec4 fragColor;

uniform float exposure = 1.0;
uniform int texOp = 1;

vec3 applyTonemap(vec3 c) {
  if (texOp == 1) return agxTonemap(c);
  if (texOp == 2) return acesFitted(c);
  if (texOp == 3) return filmicHable(c);
  if (texOp == 4) return pbrNeutral(c);
  return clamp(c, vec3(0.0), vec3(1.0));
}

void main() {
  vec3 c = max(texture(src, uv).xyz, vec3(0.0));
  c = applyTonemap(c * exposure);
  c = encodeSrgb(c);
  c = clamp(c, vec3(0.0), vec3(1.0));
  c -= (2.0 * noise3(noise(uv * 16.0)) - vec3(1.0)) / 256.0;
  c = clamp(c, vec3(0.0), vec3(1.0));
  fragColor = vec4(c, 1.0);
}