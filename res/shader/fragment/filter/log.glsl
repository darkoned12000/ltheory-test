#include filter

layout(location = 0) out vec4 fragColor;

void main() {
  vec4 color = texture(src, uv);
  vec3 rgb = max(color.xyz, vec3(0.0));
  fragColor = vec4(log(vec3(1.0) + rgb), color.a);
}
