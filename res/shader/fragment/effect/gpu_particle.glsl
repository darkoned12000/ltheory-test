/* GPU particle fragment: soft radial sprite, additive-premultiplied style
 * (color scaled by alpha, alpha channel forced to 1) matching how the engine's
 * other effect shaders feed BlendMode.Additive. */
#include fragment
#include math

layout(location = 0) out vec4 fragColor;

in vec4 pCol;
in float pFade;

void main () {
  /* Anisotropic capsule falloff: uv.x runs along the streak's length,
   * uv.y across its width. Round billboards (unstretched particles) sample
   * the same shape and still read as soft discs. */
  float ax = abs(uv.x * 2.0 - 1.0);
  float ay = abs(uv.y * 2.0 - 1.0);
  /* NOTE : smoothstep(1,0,r) would be edge0>edge1 (undefined per spec). */
  float aY = 1.0 - smoothstep(0.0, 1.0, ay);
  float aX = 1.0 - smoothstep(0.0, 1.0, ax);
  aY = aY * aY * aY;        /* steep side falloff -> visually thin core */
  float a = aY * (aX * 0.85 + 0.15) * 0.5; /* soft caps + global dim */
  fragColor = vec4(pCol.rgb * (a * pFade), 1.0);
  FRAGMENT_CORRECT_DEPTH;
}
