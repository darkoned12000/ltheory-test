#include fragment
#include color
#include gamma
#include math
#include noise

layout(location = 0) out vec4 fragColor;
uniform sampler2D srcBottom;
uniform sampler2D srcTop;

void main() {
  vec3 cb = texture(srcBottom, uv).xyz;
  vec4 ct = texture(srcTop, uv);
  ct.xyz = linear(ct.xyz);

  float l = pow(saturate(1.5 * max(0.0, ct.w)), 0.75);
  ct.z = pow(max(0.0, ct.z), 0.95);

  // Clamp noise subtraction to prevent log(0) -> -Inf / NaN UI wipes
  float nVal = clamp(noise(gl_FragCoord.xy), 0.0, 0.999);
  ct.xyz *= 1.0 - 0.02 * log(max(1e-5, 1.0 - nVal));

  vec3 c = cb * (1.0 - l) + ct.xyz;
  if (isnan(c.r) || isnan(c.g) || isnan(c.b)) {
    c = cb;
  }

  fragColor = vec4(max(vec3(0.0), c), 1.0);
}
