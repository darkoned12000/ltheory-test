#include fragment
#include color
#include deferred
#include gamma
#include math

void main() {
  vec3 normN = normalize(vertNormal);

  vec3 c = mix(
    mix(vec3(0.2, 0.1, 0.5), vec3(0.5, 0.0, 0.2), max(0.0, -normN.y)),
    mix(vec3(0.2, 0.1, 0.5), vec3(0.2, 0.6, 1.0), max(0.0,  normN.y)),
    0.5 + 0.5 * normN.y);
  c = mix(c, vec3(0.5, 0.5, 0.5), 0.25);

  c = max(c, vec3(0.0));
  float safeUV = max(0.0, uv.x);
  c *= safeUV * safeUV;

  FRAGMENT_CORRECT_DEPTH;

  setAlbedo(linear(c));
  setAlpha(1.0);
  setDepth();
  setMaterial(Material_NoShade);
  setNormal(normN);
  setRoughness(0.0);
}
