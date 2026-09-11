#include filter
#include color

layout(location = 0) out vec4 fragColor;

uniform vec2 srcSize; // Dimensions of source texture (width, height)

void main() {
  // 4-tap box sample around texel centers
  vec2 halfTexel = vec2(0.5) / srcSize;
  vec3 c00 = texture(src, uv - halfTexel).xyz;
  vec3 c10 = texture(src, uv + vec2( halfTexel.x, -halfTexel.y)).xyz;
  vec3 c01 = texture(src, uv + vec2(-halfTexel.x,  halfTexel.y)).xyz;
  vec3 c11 = texture(src, uv + halfTexel).xyz;

  // Karis weighting suppresses bright subpixel fireflies in HDR bloom pyramids
  float w00 = 1.0 / (1.0 + lum(c00));
  float w10 = 1.0 / (1.0 + lum(c10));
  float w01 = 1.0 / (1.0 + lum(c01));
  float w11 = 1.0 / (1.0 + lum(c11));
  float ws = w00 + w10 + w01 + w11;

  fragColor = vec4((c00 * w00 + c10 * w10 + c01 * w01 + c11 * w11) / ws, 1.0);
}
