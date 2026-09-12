#include fragment
#include deferred
#include gamma
#include fdm
#include color
#include math
#include fog

#autovar vec3 eye

uniform sampler2D texDiffuse;
uniform float scale;

void main() {
  vec3 N = normalize(normal);
  vec3 V = normalize(pos - eye);

  float safeScale = max(1e-4, scale);
  vec3 c = linear(sampleFDM(texDiffuse, safeScale * vertPos.xyz).xyz);

  float safeUV = max(0.0, uv.x);
  c *= safeUV;
  c = clamp(c, vec3(0.0), vec3(1.0));

  FRAGMENT_CORRECT_DEPTH;

  setAlbedo(c);
  setAlpha(1.0);
  setDepth();
  setNormal(N);
  setRoughness(1.0);
  setMaterial(Material_Diffuse);
}
