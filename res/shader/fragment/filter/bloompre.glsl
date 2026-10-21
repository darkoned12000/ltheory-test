#include filter
#include color
#include math

layout(location = 0) out vec4 fragColor;

uniform float bloomThreshold;
uniform float bloomKnee;

void main() {
  vec3 c = max(texture(src, uv).xyz, vec3(0.0));
  // The clamp the bloom pre-filter applies before the mip chain.
  //
  // This used to be a `maxBrightness` uniform with an in-shader fallback of
  // 5.0 -- and nothing EVER uploaded it, so the uniform sat at 0 and the
  // fallback is what always ran. The knob was a lie: it looked configurable
  // and was not. It is now the constant it actually was.
  c = min(c, vec3(5.0));

  float br = max(c.r, max(c.g, c.b));
  float soft = clamp(br - bloomThreshold + bloomKnee, 0.0, 2.0 * bloomKnee);
  soft = (soft * soft) / (4.0 * bloomKnee + 1e-4);
  float mult = max(br - bloomThreshold, soft) / max(br, 1e-4);

  fragColor = vec4(c * mult, 1.0);
}
