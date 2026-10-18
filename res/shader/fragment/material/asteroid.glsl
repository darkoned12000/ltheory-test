#include fragment
#include deferred
#include gamma
#include fdm
#include color
#include math
#include fog

#autovar vec3 eye

// Asteroid-field distance fade ("curtain"). See AsteroidField.
//
// The streamed field loads rocks out to rockFadeFar, and the camera has NO far
// plane (Camera.zFar = 1e6), so without this the stream boundary is rendered in
// plain sight and rocks visibly pop in.
//
//   rockFadeNear = fully solid inside this distance
//   rockFadeFar  = fully gone beyond it
// Far >> Near disables it entirely, which is what the field does when it is off,
// so ordinary asteroids are never touched.
//
// This is a FRAGMENT DISCARD, not a scale animation, and that distinction is the
// whole point. Scaling a rock to hide it makes it visibly INFLATE IN PLACE --
// play-testing caught exactly that ("it's very obvious the asteroids are growing
// in front of me instead of slightly getting bigger as I get closer"). A rock
// here is always at its true size and simply is not drawn until you are close
// enough, so it reads as distance rather than as growth.
//
// It also makes a large field nearly free: the discard happens before any texture
// sample or G-buffer write, so the thousands of far rocks that make up the bulk of
// a streamed field cost one distance calculation each.
//
// Dithered rather than blended, because the deferred G-buffer is opaque. Blending
// would need sorted draws and would break depth writes. Interleaved gradient
// noise resolves a partial value into a fine screen-space stipple that reads as a
// smooth fade, and TAA (the next task) collapses it completely.
#autovar float rockFadeNear
#autovar float rockFadeFar

// An autovar directive only REGISTERS the name for the per-draw stack upload;
// the engine strips the directive before glShaderSource, so the uniform still
// has to be declared for real (same pattern as sunFill in light/global.glsl).
// NB: never write the directive itself literally in a shader comment -- the
// engine's preprocessor does a raw substring search for it anywhere in the
// file, comments included, and will parse the rest of that line as a directive
// and abort the boot. The validator does not catch this.
uniform float rockFadeNear;
uniform float rockFadeFar;

uniform sampler2D texDiffuse;
uniform float scale;

// Interleaved gradient noise (Jimenez). Cheap, and far better distributed than a
// hash of gl_FragCoord, so the stipple does not clump into visible blotches.
float rockFadeDither (vec2 p) {
  return fract(52.9829189 * fract(dot(p, vec2(0.06711056, 0.00583715))));
}

void main() {
  // FIRST THING in main: everything after this is per-fragment work we skip
  // entirely for a rock that is not going to be drawn.
  float camDist = length(pos - eye);
  float vis = 1.0 - smoothstep(rockFadeNear, rockFadeFar, camDist);
  if (vis < rockFadeDither(gl_FragCoord.xy)) discard;

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
