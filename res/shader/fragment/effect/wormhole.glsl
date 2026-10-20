// The WORMHOLE: the glow inside a jumpgate.
//
// PORTED FROM THE ORIGINAL LIMIT THEORY (Warping/wormhole.jsl).
//
// The old version raymarched a fractal -- a Mandelbulb-style distance
// estimator -- along the ray from the portal's surface toward the eye, and
// accumulated the glow. The fractal is concentrated into a bright knot at
// the centre of the gate, which is what reads as "a hole with something in
// it".
//
// The old version MIXED SPACES: it started the march at the normalised
// LOCAL vertex position but marched along a WORLD direction. That is only
// correct for an unrotated object, and it happened to work because the
// portal model was an unrotated unit sphere. Here the eye is brought into
// OBJECT space properly, so the fractal is always centred on the gate and
// the march always goes the right way.
//
// The gate is drawn ADDITIVELY and with culling off, so you see the INSIDE
// of the sphere -- you are meant to be looking at the throat of the portal,
// not at a ball.

#include fragment
#include color
#include scattering

layout(location = 0) out vec4 outColor;

uniform float time;

// The eye, in the gate's OBJECT space (the mesh is a unit sphere at the
// origin, scaled by the entity's scale).
//
// It is passed in rather than derived from the world matrix because the
// transform needed here is the INVERSE of the world matrix -- "where is the
// eye relative to this gate" -- and the only inverse the shader has is the
// inverse-TRANSPOSE (mWorldIT), which is a different matrix whenever there
// is a translation. The gate has no rotation, so the local direction to the
// eye is just the world offset divided by the scale, and Lua can compute
// it exactly.
uniform vec3 eyeLocal;

const int kSamples = 8;

// The fractal. Each step folds the point back towards the origin and
// accumulates the change in the distance; the exponential term concentrates
// the result into the middle of the gate.
float field(vec3 p) {
  vec4 z = vec4(p.xyz, 0.5);
  vec4 kOffset = vec4(0.4 + 0.2 * cos(time / 4.0),
                      0.7 + 0.2 * sin(time / 3.32),
                      0.5, 0.5);
  z += 0.2;
  float a = 0, l = 0;
  for (int i = 0; i < 10; ++i) {
    float m = dot(z, z);
    z = abs(z) / m - kOffset;
    a += abs(m - l);
    l = m;
  }
  a *= 0.05 * exp(-10.0 * dot(p, p));
  return a;
}

void main() {
  float a = 0;
  vec3 ro = vertPos;                          // on the unit sphere
  vec3 rd = normalize(eyeLocal - ro);
  // How far the ray crosses the sphere before it leaves on the far side.
  float t = interSphere(vec4(0, 0, 0, 1.0001), ro, rd).y;
  rd *= t / float(kSamples);
  for (int i = 0; i < kSamples; ++i) {
    a += field(ro);
    ro += rd;
  }
  a /= float(kSamples);
  a = clamp(a, 0.0, 1.0);

  // The old colour: a cold blue-white, scaled by the accumulated glow.
  vec3 c = 4.0 * a * vec3(1.0, 1.5, 2.0);
  outColor = vec4(c, 1.0);
}
