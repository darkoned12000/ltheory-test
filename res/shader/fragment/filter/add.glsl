#include filter

layout(location = 0) out vec4 fragColor;

uniform sampler2D src1;
uniform sampler2D src2;
uniform float mult1;
uniform float mult2;

void main() {
  vec4 c1 = texture(src1, uv);
  vec4 c2 = texture(src2, uv);
  fragColor = max(vec4(0.0), mult1 * c1 + mult2 * c2);
}
