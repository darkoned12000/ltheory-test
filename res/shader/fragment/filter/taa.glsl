// Temporal anti-aliasing (TAA) resolve.
//
// WHY THIS REPLACES SUPERSAMPLING
// `render.superSample` scales the ENTIRE internal buffer (Renderer:start does
// sx = ss*resX), so 4x cost 16x the pixels of every pass -- geometry, deferred
// lighting, SSAO, bloom and the volumetric march alike -- and none of those
// except geometry gain anything from it. Measured: 4K at 50% + 4x is 33.2 MP and
// ran at 27 fps; 4K at 100% with no supersampling runs at 4.7 ms. TAA reaches
// comparable edge quality at ~1x, which is what every current 4K title does
// (they use TAA, not brute-force SSAA -- that comparison is why they hit 60).
//
// WHY THE JITTER IS APPLIED IN THE VERTEX SHADER, NOT TO mProj
// The textbook implementation jitters the projection matrix itself. That is not
// available here: the Matrix struct is not exposed to Lua, so mProj cannot be
// modified without a C++ change. More importantly, this engine reconstructs world
// rays for the nebula/god-ray march from mProjInv, so jittering the shared
// projection would be a live risk to work that is already tuned and signed off.
//
// So the jitter is applied per-vertex instead, in vertex/wvp.glsl, as a clip-space
// offset multiplied by w (a true constant NDC offset, depth-independent). Crucially
// mView/mProj/mProjInv all stay UNJITTERED, so ray reconstruction is bit-for-bit
// unchanged and only the rasterisation of geometry moves. This resolve then
// samples the scene back at that same jittered position, which is what closes the
// loop -- the offset has to match or the resolve resamples the wrong spot.
//
// Resampling the resolve WITHOUT jittering the geometry does NOT work, and was
// measured: it moved the image only 0.1% closer to a 4x SSAA reference, because
// shifting a sample inside an already-rasterised pixel cannot invent coverage on a
// hard edge -- it only blurs. Moving the EDGE before rasterisation is what produces
// the per-frame coverage diversity that accumulates into smooth edges.
//
// REPROJECTION
// Depth-based, no velocity buffer. That is viable here specifically because the
// world is almost entirely static: the streamed asteroid field's rocks never
// move, planets rotate at ~0.02 rad/s (sub-pixel per frame), and only NPCs
// translate on their own. For a static world with a moving camera, depth
// reprojection is essentially exact, so there is almost nothing to ghost. NPCs
// are the one known artifact source and they occupy few pixels.

#include fragment
#include color
#include math

layout(location = 0) out vec4 fragColor;

// The camera matrices are autovars: they are pushed once per frame by
// Camera:beginDraw and read by every draw.
//
// NOTE: taaJitter/taaJitterPrev are autovars HERE, and Renderer:taa deliberately
// does NOT Shader.Set* them. Shader_Start fetches every declared autovar from the
// ShaderVar STACK and Fatal-aborts if it is absent, so the two must agree: they
// must be declared autovar here AND pushed on the stack by Camera:beginDraw,
// because the geometry was rasterised with that same jitter and the resolve has to
// read the image back from where it was actually written. Setting one via
// Shader.Set* while it is also an autovar is the mismatch that aborts the frame.
//
// taaTexel, taaBlend and taaValid are NOT autovars -- they are per-pass constants
// set with Shader.Set* in Renderer:taa. taaValid in particular is owned by the
// Renderer, NOT by Camera: only the Renderer knows whether the history buffers
// exist yet and have been written at least once. Camera's "we have drawn a frame"
// flag is true on frame 2 even when TAA was switched on this instant or the window
// was just resized -- and the history texture is then brand new and UNINITIALISED,
// so blending against it would mix in garbage (possibly NaN, which clamp() does
// not reliably scrub) for a frame.
//
// NOTE the direction of each matrix, which is easy to get backwards here:
//   mProjInv   NDC -> view   (a point on the near plane for this pixel)
//   mViewInv   view  -> world (Camera sets mViewInv = FromPosRot, mView = its
//                            inverse, so despite the names mViewInv is the
//                            WORLD matrix)
//   mViewProjPrev  world -> previous frame's clip
uniform mat4 mProjInv;
uniform mat4 mViewInv;
uniform mat4 mViewProjPrev;
uniform vec2 taaJitter;
uniform vec2 taaJitterPrev;
uniform vec2 taaTexel;
uniform float taaBlend;
uniform float taaValid;

#autovar mat4 mProjInv
#autovar mat4 mViewInv
#autovar mat4 mViewProjPrev
#autovar vec2 taaJitter
#autovar vec2 taaJitterPrev

uniform sampler2D texScene;
uniform sampler2D texDepth;    // zBufferL: LINEAR eye distance, not [0..1] depth
uniform sampler2D texHistory;

void main() {
  // Sample THIS frame at the sub-pixel position the geometry was rasterised at.
  // The jitter was applied to the projection (vertex/wvp.glsl), so reading on the
  // un-jittered pixel centre would resample the wrong spot entirely.
  vec2 suv = uv + taaJitter * 0.5;

  vec3 cur = texture(texScene, suv).rgb;
  vec3 outc = cur;

  // Frame 0 has no history to blend, and after a resize the reprojection is
  // meaningless (different dimensions), so both fall back to the raw frame.
  if (taaValid > 0.5 && taaBlend > 0.0) {
    // World position from the linear eye distance. zBufferL holds distance along
    // the view ray, not NDC depth, so it cannot be fed to an inverse
    // view-projection directly: take the view-space point on the near plane for
    // this pixel and scale that ray out to the measured distance.
    float zL = texture(texDepth, suv).r;
    // The depth sample is taken at the rasterized (jittered) UV, but mProjInv
    // is intentionally UNJITTERED. Undo the clip-space jitter before building
    // the view ray. `uv` is that unjittered pixel; using `suv` here applied the
    // jitter twice to world reconstruction and weakened temporal reprojection.
    vec4 vh = mProjInv * vec4(uv * 2.0 - 1.0, -1.0, 1.0);
    vh /= vh.w;
    // Eye distance is positive in front of the camera, where view z is negative.
    vec3 viewPos = vh.xyz * (zL / max(1e-6, -vh.z));
    vec3 worldPos = (mViewInv * vec4(viewPos, 1.0)).xyz;

    vec4 pp = mViewProjPrev * vec4(worldPos, 1.0);
    // Reprojection lands in LAST frame's UN-jittered screen space, but the
    // history was written at last frame's JITTERED position. Adding last frame's
    // jitter here is what makes the fetch land on the texel that actually holds
    // that history. Without it the sample is off by up to half a pixel per axis,
    // which is enough to blur edges instead of resolving them.
    vec2 puv = (pp.xy / pp.w) * 0.5 + 0.5 + taaJitterPrev * 0.5;

    // Reprojected off-screen (or behind the camera) => no history for this pixel.
    if (all(greaterThanEqual(puv, vec2(0.0))) && all(lessThanEqual(puv, vec2(1.0)))) {
      vec3 hist = texture(texHistory, puv).rgb;

      // Neighbourhood clamp. Without it, anything that moved between frames
      // smears: the history colour is restricted to the bounding box of the 3x3
      // neighbourhood of the CURRENT frame, so a pixel can only ever blend with
      // colours that are plausible right now. This is what removes ghosting on
      // disocclusions and on the NPCs, and it is why no velocity buffer is
      // needed for a static world.
      vec3 mn = cur;
      vec3 mx = cur;
      for (int y = -1; y <= 1; ++y) {
        for (int x = -1; x <= 1; ++x) {
          vec3 n = texture(texScene, suv + vec2(float(x), float(y)) * taaTexel).rgb;
          mn = min(mn, n);
          mx = max(mx, n);
        }
      }
      vec3 hc = clamp(hist, mn, mx);
      outc = mix(cur, hc, taaBlend);
    }
  }

  fragColor = vec4(outc, 1.0);
}
