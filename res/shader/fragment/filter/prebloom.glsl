#include fragment
#include math
#include color


layout(location = 0) out vec4 fragColor;
uniform sampler2D src;

void main() {
  vec3 c = texture(src, uv).xyz;
  float a = 1.0 + avg(c);
  fragColor = vec4(c, a);
}
