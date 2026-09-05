#include filter
#include noise

layout(location = 0) out vec4 fragColor;

uniform float strength = 1.0;
uniform float time = 0.0;

void main() {
  vec3 c = texture(src, uv).xyz;
  vec2 px = uv * size;
  float g = noise(vec2(px.x, px.y + 97.0 * time));
  g = 0.5 + (g - 0.5) * 0.7;
  c += (g - 0.5) * clamp(strength, 0.0, 8.0) * 0.06;
  c = max(c, vec3(0.0));
  fragColor = vec4(c, 1.0);
}