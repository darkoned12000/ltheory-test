#include filter

layout(location = 0) out vec4 fragColor;

void main() {
  vec4 c = texture(src, uv);
  c.xyz = clamp(vec3(1.0) - c.xyz, 0.0, 1.0);
  fragColor = c;
}
