#include filter

layout(location = 0) out vec4 fragColor;

uniform vec4 add;
uniform vec4 mult;

void main() {
  fragColor = mult * texture(src, uv) + add;
}
