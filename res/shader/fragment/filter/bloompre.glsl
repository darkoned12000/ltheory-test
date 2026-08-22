#include fragment
#include math
#include color


layout(location = 0) out vec4 fragColor;
uniform sampler2D src;

void main() {
  vec3 c = texture(src, uv).xyz;
  float a = lum(c);
  // c *= (1.0 - exp(-lum(c))) / lum(c);
  fragColor = vec4(c, a);
}
