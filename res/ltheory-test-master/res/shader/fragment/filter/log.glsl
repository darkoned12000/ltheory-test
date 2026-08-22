#include filter


layout(location = 0) out vec4 fragColor;
void main() {
  fragColor = log(vec4(1.0) + texture(src, uv));
}
