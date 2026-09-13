#include fragment

layout(location = 0) out vec4 fragColor;
uniform sampler2D tex;
uniform vec4 color;

void main() {
  vec4 texColor = texture(tex, uv);
  vec4 c = color * texColor;

  if (isnan(c.r) || isnan(c.g) || isnan(c.b) || isnan(c.a)) {
    c = vec4(0.0);
  }

  fragColor = c;
}
