#include fragment
#include deferred
#include gamma
#include fdm
#include color
#include math

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
// would need sorted draws and would break depth writes.
//
// It resolves a partial value into stochastic alpha -- "discard this pixel with
// probability (1 - vis)". That is only SMOOTH if the threshold varies over time
// and something integrates it; see ditherOffset and Camera:beginDraw. A static
// per-pixel threshold produces a fixed screen-space stipple that crawls across
// moving geometry, and TAA cannot fix it (every frame yields the same dots, so
// the history converges straight back onto them).
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

// Per-frame rotation of the dither threshold, pushed by Camera:beginDraw. It is
// (0,0) unless TAA is running -- see the note in Camera.lua for why a dither
// that varies per frame is only safe when something integrates it.
#autovar vec2 ditherOffset
uniform vec2 ditherOffset;

// Share GameView's 64x64 frequency-ranked blue-noise tile with GTAO/volumetrics.
// Blue noise keeps the fade's stipple energy in high spatial frequencies instead
// of the coarse, visibly clumpy grain a pixel hash produced on large surfaces.
#autovar sampler2D rockFadeNoise
uniform sampler2D rockFadeNoise;

uniform sampler2D texDiffuse;
uniform float scale;

float rockFadeDither (vec2 p) {
  // 64 is the shared blue-noise LUT size. Give every screen-space tile its own
  // toroidal phase so the 64x64 LUT does not visibly repeat as a checker across
  // a large fading surface. Integer wrap keeps it stable with TAA off;
  // Camera's per-frame offset decorrelates samples when TAA is on.
  ivec2 pixel = ivec2(p);
  ivec2 tile = pixel >> 6;
  uint h = uint(tile.x) * 0x27d4eb2du + uint(tile.y) * 0x165667b1u;
  h ^= h >> 15; h *= 0x2c1b3c6du;
  h ^= h >> 12; h *= 0x297a2d39u;
  h ^= h >> 15;
  ivec2 phase = ivec2(int(h & 63u), int((h >> 6) & 63u));
  ivec2 q = (pixel + phase) & ivec2(63);
  return texelFetch(rockFadeNoise, q, 0).r;
}

void main() {
  // FIRST THING in main: everything after this is per-fragment work we skip
  // entirely for a rock that is not going to be drawn.
  float camDist = length(pos - eye);
  float vis = 1.0 - smoothstep(rockFadeNear, rockFadeFar, camDist);
  // ditherOffset is what makes this a STOCHASTIC alpha rather than a fixed
  // screen-space stipple. With TAA running it changes every frame (golden-ratio
  // sequence), so consecutive frames discard different subsets of pixels and the
  // history blend integrates them into true partial coverage. With a static
  // threshold the same dots are produced every frame, TAA converges straight back
  // onto them, and they crawl visibly across a moving rock.
  // Do not even sample the dither LUT when the fade is disabled or the fragment
  // is inside the fully-visible region.
  if (camDist > rockFadeNear
      && vis < rockFadeDither(gl_FragCoord.xy + ditherOffset)) discard;

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
