#include filter

layout(location = 0) out vec4 fragColor;

uniform sampler2D srcBottom;
uniform sampler2D srcTop;

void main() {
  vec3 cb = texture(srcBottom, uv).xyz;
  vec4 ct = texture(srcTop, uv);
  float alpha = clamp(ct.w, 0.0, 1.0);
  vec3 c = cb * (1.0 - alpha) + ct.xyz;
  fragColor = vec4(c, 1.0);
}
