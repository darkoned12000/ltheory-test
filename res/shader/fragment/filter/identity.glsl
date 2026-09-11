#include filter

layout(location = 0) out vec4 fragColor;

void main() {
  fragColor = texture(src, uv);
}
