#include filter
#include color
#include math

layout(location = 0) out vec4 fragColor;

uniform sampler2D srcBlur;
uniform float intensity;

void main() {
  vec3 scene = max(texture(src, uv).xyz, vec3(0.0));
  vec3 bloom = max(texture(srcBlur, uv).xyz, vec3(0.0));
  fragColor = vec4(scene + intensity * bloom, 1.0);
}