/* GPU particle fragment: soft radial sprite, additive-premultiplied style
 * (color scaled by alpha, alpha channel forced to 1) matching how the engine's
 * other effect shaders feed BlendMode.Additive. */
#include fragment
#include math

layout(location = 0) out vec4 fragColor;

in vec4 pCol;
in float pFade;

void main () {
  float r = length(uv * 2.0 - 1.0);
  /* NOTE : smoothstep(1,0,r) would be edge0>edge1 (undefined per spec). */
  float a = 1.0 - smoothstep(0.0, 1.0, r);
  a *= a; /* sharper core, softer edge */
  fragColor = vec4(pCol.rgb * (a * pFade), 1.0);
  FRAGMENT_CORRECT_DEPTH;
}
