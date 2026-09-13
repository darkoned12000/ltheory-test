#include fragment

layout(location = 0) out vec4 fragColor;
uniform sampler2D glyph;
uniform vec4 color;

void main() {
  float sampleW = texture(glyph, uv).w;
  float alpha = sqrt(max(0.0, sampleW));
  vec3 c = color.xyz;
  vec4 outCol = alpha * color.w * vec4(c, 1.0);

  if (isnan(outCol.r) || isnan(outCol.g) || isnan(outCol.b) || isnan(outCol.a)) {
    outCol = vec4(0.0);
  }

  fragColor = max(vec4(0.0), outCol);
}
