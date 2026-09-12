#include fragment
#include deferred
#include gamma
#include fdm
#include color
#include math
#include fog

#autovar vec3 eye
#autovar samplerCube envMap

uniform sampler2D texDiffuse;
uniform float scale;

void main() {
  vec3 N = normalize(normal);
  vec3 V = normalize(pos - eye);
  vec3 R = normalize(reflect(V, N));

  float safeScale = max(1e-4, scale);
  vec3 c = sampleFDM(texDiffuse, safeScale * vertPos.xyz).xyz;
  c *= 8.0 * c;
  c *= (1.0 + c.x * c.x * vec3(1.0, 3.0, 5.0));
  float rough = saturate(c.x * c.x);
  vec3 env = textureLod(envMap, R, 0.0).xyz;

  c = sqrt(max(vec3(0.0), c * env * env));
  c = applyFog(c, V);

  if (isnan(c.r) || isnan(c.g) || isnan(c.b)) {
    c = vec3(0.0);
  }

  FRAGMENT_CORRECT_DEPTH;

  setAlbedo(clamp(c, vec3(0.0), vec3(1.0)));
  setAlpha(1.0);
  setDepth();
  setNormal(N);
  setRoughness(clamp(mix(0.6, 0.9, rough), 0.0, 1.0));
  setMaterial(Material_Diffuse);
}
