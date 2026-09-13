#include fragment

layout(location = 0) out vec4 fragColor;
uniform vec4 color;
uniform sampler2D icon;

void main() {
  vec3 c = color.xyz;
  float alpha = texture(icon, uv).w;
  vec4 outCol = alpha * color.w * vec4(c, 1.0);

  if (isnan(outCol.r) || isnan(outCol.g) || isnan(outCol.b) || isnan(outCol.a)) {
    outCol = vec4(0.0);
  }

  fragColor = outCol;
}
