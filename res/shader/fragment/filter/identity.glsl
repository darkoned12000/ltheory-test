#include fragment


layout(location = 0) out vec4 outColor;
uniform sampler2D src;

void main() {
  outColor = texture(src, uv);
}
