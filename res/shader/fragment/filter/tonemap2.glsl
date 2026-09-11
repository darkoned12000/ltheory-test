#include filter

layout(location = 0) out vec4 fragColor;

const float K = 1.50;
const float P = 1.25;

void main() {
  vec3 c = max(texture(src, uv).xyz, vec3(0.0));
  c = vec3(1.0) - vec3(1.0) / (vec3(1.0) + K * pow(c, vec3(P)));
  fragColor = vec4(max(c, vec3(0.0)), 1.0);
}
