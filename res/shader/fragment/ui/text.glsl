#include fragment


layout(location = 0) out vec4 fragColor;
uniform sampler2D glyph;
uniform vec4 color;

void main() {
  float alpha = sqrt(texture(glyph, uv).w);
  vec3 c = color.xyz;
  fragColor = alpha * color.w * vec4(c, 1.0);
}
