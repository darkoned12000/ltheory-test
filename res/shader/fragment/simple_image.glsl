#include fragment


layout(location = 0) out vec4 outColor;
uniform sampler2D image;

void main() {
  outColor = texture(image, uv);
}
