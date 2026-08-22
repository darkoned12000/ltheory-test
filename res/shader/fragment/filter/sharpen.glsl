#include fragment


layout(location = 0) out vec4 fragColor;
uniform float strength;
uniform sampler2D src;
uniform sampler2D srcBlur;

void main() {
  vec3 c = texture(src, uv).xyz;
  vec3 mask = texture(srcBlur, uv).xyz;
  vec3 hp = c - mask;
  c += strength * hp;
  fragColor = vec4(c, 1.0);
}
