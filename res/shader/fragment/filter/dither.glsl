#include filter
#include math
#include noise

layout(location = 0) out vec4 fragColor;

void main() {
  vec3 c = texture(src, uv).xyz;
  // High-frequency procedural noise subtraction to prevent 8-bit color banding
  vec3 dither = (2.0 * noise3(noise(uv * 16.0)) - vec3(1.0)) / 256.0;
  fragColor = vec4(clamp(c - dither, 0.0, 1.0), 1.0);
}
