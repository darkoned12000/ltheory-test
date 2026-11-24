/* Anamorphic lens flare: horizontal threshold blur. */
#include filter

layout(location = 0) out vec4 fragColor;

uniform float threshold;
uniform float strength;
uniform int radius;

void main() {
  vec3 acc = vec3(0.0);
  float wsum = 0.0;
  for (int i = -radius; i <= radius; i++) {
    vec2 off = vec2(float(i) / size.x, 0.0);
    vec3 c = texture(src, uv + off).rgb;
    float lum = dot(c, vec3(0.2126, 0.7152, 0.0722));
    float w = (lum > threshold) ? (lum - threshold) : 0.0;
    float g = exp(-float(i*i) / (2.0 * float(radius*radius + 1)));
    acc += c * w * g;
    wsum += w * g;
  }
  vec3 flare = (wsum > 0.0) ? (acc / wsum) * strength : vec3(0.0);
  vec3 base = texture(src, uv).rgb;
  fragColor = vec4(base + flare, 1.0);
}
