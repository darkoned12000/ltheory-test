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

// Dither threshold for the curtain fade.
//
// This was interleaved gradient noise, which was WRONG: IGN is designed to be
// low-discrepancy ACROSS the frame, and at one sample per pixel that structure
// is visible on its own. Play-testing caught it as a regular grid woven across
// mid-distance asteroid surfaces and vertical banding across the smooth nebula
// -- the artifacts appeared in exactly the fade band, which is the tell.
//
// A plain integer hash is unstructured, so it reads as even grain rather than as
// a pattern. It is stable per pixel (no shimmer), and it is the right choice until
// the 64x64 blue-noise texture can be bound here: blue noise is visibly better,
// but it needs plumbing through Material, whereas this is self-contained.
float rockFadeDither (vec2 p) {
  // Integer hash (Wang / sin-free). sin-based hashes band badly on some drivers.
  uint x = uint(int(p.x) + 32768);
  uint y = uint(int(p.y) + 32768);
  uint h = x * 0x27d4eb2du + y * 0x165667b1u;
  h ^= h >> 15; h *= 0x2c1b3c6du;
  h ^= h >> 12; h *= 0x297a2d39u;
  h ^= h >> 15;
  return float(h) / 4294967295.0;
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
