#include filter

layout(location = 0) out vec4 fragColor;

uniform sampler2D srcLow;
uniform float scatter;

void main() {
  vec3 high = texture(src, uv).xyz;
  vec3 low = texture(srcLow, uv).xyz;
  fragColor = vec4(mix(high, low, scatter), 1.0);
}