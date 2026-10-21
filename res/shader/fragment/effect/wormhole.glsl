// The WORMHOLE: the glow inside a jumpgate.
//
// PORTED FROM THE ORIGINAL LIMIT THEORY (Warping/wormhole.jsl).
//
// The old version raymarched a fractal -- a Mandelbulb-style distance
// estimator -- along the ray from the portal's surface toward the eye, and
// accumulated the glow.
//
// The old version MIXED SPACES: it started the march at the normalised
// LOCAL vertex position but marched along a WORLD direction. That is only
// correct for an unrotated object, and it happened to work because the
// portal model was an unrotated unit sphere. Here the eye is brought into
// object space properly, so the fractal is always centred on the gate.
//
// NOTE ON THE EYE UNIFORM: eyeLocal is the eye in the gate's own frame,
// computed on the CPU as (eye - gateCentre) / scale. That is EXACT for a
// gate with a scale and a translation and NO ROTATION, which is what a gate
// is. If gates ever get rotated, this has to become a full inverse(world)
// matrix -- an inverse-transpose is not the same thing, because the
// translation has to be included.
//
// The gate is drawn ADDITIVELY with culling off, so you see the INSIDE of
// the throat: the near wall and the far wall both contribute, and the
// fractal's knot glows between them.

#include fragment
#include color
#include scattering

layout(location = 0) out vec4 outColor;

// The eye, in the gate's OBJECT space (the mesh is a unit sphere at the
// origin, scaled by the entity's scale).
uniform vec3 eyeLocal;

uniform float time;

const int kSamples = 8;

// The fractal. Each step folds the point back towards the origin and
// accumulates the change in the distance; the exponential term concentrates
// the result into a knot in the middle of the gate.
//
// `kOffset` is passed in rather than computed here: it is a cos and a sin,
// and the old version evaluated them on EVERY field() call -- eight times
// per pixel -- for a value that only depends on time. This is the same
// value, so the look is unchanged.
float field(vec3 p, vec4 kOffset) {
  vec4 z = vec4(p.xyz, 0.5);
  z += 0.2;
  float a = 0, l = 0;
  for (int i = 0; i < 10; ++i) {
    float m = dot(z, z);
    // The guard: if m reaches zero, abs(z)/m is 0/0 -- a NaN -- and under
    // additive blending a NaN shows up as a black or blown-out pixel.
    // clamp() on the result does not reliably clean that up. This only
    // changes the degenerate case; the look is the same.
    z = abs(z) / max(m, 1e-6) - kOffset;
    a += abs(m - l);
    l = m;
  }
  a *= 0.05 * exp(-10.0 * dot(p, p));
  return a;
}

void main() {
  float a = 0;
  vec3 ro = vertPos;
  vec3 rd = normalize(eyeLocal - ro);
  // How far the ray crosses the sphere before it leaves on the far side.
  float t = interSphere(vec4(0, 0, 0, 1.0001), ro, rd).y;
  rd *= t / float(kSamples);

  // The band that drifts across the fractal, computed once per pixel.
  vec4 kOffset = vec4(0.4 + 0.2 * cos(time / 4.0),
                      0.7 + 0.2 * sin(time / 3.32),
                      0.5, 0.5);

  for (int i = 0; i < kSamples; ++i) {
    a += field(ro, kOffset);
    ro += rd;
  }
  a /= float(kSamples);
  a = clamp(a, 0.0, 1.0);

  // The old colour: a cold blue-white, scaled by the accumulated glow.
  vec3 c = 4.0 * a * vec3(1.0, 1.5, 2.0);
  outColor = vec4(c, 1.0);
}
