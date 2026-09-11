#include fragment
#include math
#include color

layout(location = 0) out vec4 fragColor;

uniform sampler2D src;
uniform sampler2D srcBlur;
uniform float strength;

// Safe luminance normalization guarded against division-by-zero
vec3 normalum (vec3 x) {
  return x / max(lum(x), 1e-5);
}

void main() {
  vec3 c1 = max(texture(src, uv).xyz, vec3(0.0));
  vec4 c2w = texture(srcBlur, uv);
  vec3 c2 = max(c2w.xyz, vec3(0.0));

  vec3 c = c1;
  vec3 dark = sqrt(c1 * c2);
  c = mix(c, dark, 0.1);

  // Tinted glare overlay (creates subtle spectral flares around thrusters/stars)
  vec3 glowTint = mix(normalum(c2), normalum(vec3(0.1, 0.3, 1.0)), 0.4);
  c += 0.25 * strength * glowTint * pow(lum(c2), 1.5);

  fragColor = vec4(c, 1.0);
}
