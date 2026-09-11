#include filter
#include color
#include math

layout(location = 0) out vec4 fragColor;

uniform float bloomThreshold;
uniform float bloomKnee;
uniform float maxBrightness; // Exposes hardcoded clamp (default: 5.0 to 20.0)

void main() {
  vec3 c = max(texture(src, uv).xyz, vec3(0.0));
  float maxB = (maxBrightness > 0.0) ? maxBrightness : 5.0;
  c = min(c, vec3(maxB));

  float br = max(c.r, max(c.g, c.b));
  float soft = clamp(br - bloomThreshold + bloomKnee, 0.0, 2.0 * bloomKnee);
  soft = (soft * soft) / (4.0 * bloomKnee + 1e-4);
  float mult = max(br - bloomThreshold, soft) / max(br, 1e-4);

  fragColor = vec4(c * mult, 1.0);
}
