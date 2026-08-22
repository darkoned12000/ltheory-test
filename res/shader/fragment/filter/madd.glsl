
layout(location = 0) out vec4 fragColor;
in vec2 uv;

uniform sampler2D src;
uniform vec4 add;
uniform vec4 mult;

void main() {
  fragColor = mult * texture(src, uv) + add;
}
