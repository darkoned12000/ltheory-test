#include fragment

/* UI-over-finalized-picture overlay (post-tonemap): both srcBottom (final
 * scene, display space) and srcTop (UI, drawn colors) are already gamma-coded,
 * so a straight alpha mix keeps the widgets exactly as authored. */
layout(location = 0) out vec4 fragColor;
uniform sampler2D srcBottom;
uniform sampler2D srcTop;

void main() {
  vec3 cb = texture(srcBottom, uv).xyz;
  vec4 ct = texture(srcTop, uv);
  vec3 c = cb * (1.0 - ct.w) + ct.xyz;
  fragColor = vec4(c, 1.0);
}