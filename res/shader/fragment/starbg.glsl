#include fragment
#include deferred
#include gamma
#include color
#include math

void main() {
  float r = length(uv);
  float a = 0.0;
  // Was: float fog = getFoginess(farPlane). getFoginess() is gone -- it had no
  // caller and nothing ever uploaded its `fogDensity` uniform (see
  // res/shader/include/lighting.glsl). `fog` has always been 0.0 here.
  float fog = 0.0;
  vec4 bg = linear(texture(envMap, vertPos));
  vec3 c = vertNormal;
  c *= mix(vec3(1.0), bg.xyz, 0.5);
  a += 0.5 * exp(-9.0 * sqrt(r));
  a += 1.0 * exp(-pow2(30.0 * r));
  c *= a*a;

  if (a < 0.02) discard; // star quads span ~4 degrees; without this they paint near-black squares over the skybox

  setAlbedo(c.xyz);
  setAlpha(1.0);
}
