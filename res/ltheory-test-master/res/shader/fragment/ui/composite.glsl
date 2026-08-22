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
  float l = pow(saturate(1.5 * ct.w), 0.75);
  ct.z = pow(ct.z, 0.95);
  ct.xyz *= 1.0 - 0.02 * log(1.0 - noise(gl_FragCoord.xy));
  vec3 c = cb * (1.0 - l) + ct.xyz;
  fragColor = vec4(c, 1.0);
}
