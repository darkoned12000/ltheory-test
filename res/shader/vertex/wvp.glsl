/* -- World-View-Projection ----------------------------------------------------
   The standard projection pipeline for game objects in world-space.

   Requires:
     * An active camera to provide view & projection matrices
     * mWorld matrix providing object's local->world transform
     * mWorldIT matrix (inverse-transpose of mWorld)
----------------------------------------------------------------------------- */

#include vertex

#autovar mat4 mView
#autovar mat4 mProj

// TAA sub-pixel jitter, in NDC. Zero when TAA is off, so this costs one multiply
// and changes nothing.
//
// This is the WHOLE POINT of the TAA resolve, and the reason jittering the
// resolve's sample offset instead is not equivalent. Shifting a sample within an
// already-rasterised pixel cannot invent coverage: a pixel on a hard edge is
// fully covered or fully uncovered, so sub-pixel resampling only blurs. Moving
// the EDGE by a sub-pixel amount before rasterisation is what produces genuinely
// different coverage per frame, and it is that diversity which accumulates into
// smooth edges. Measured: resample-only jitter moved the image 0.1% closer to a
// 4x SSAA reference, i.e. it was not antialiasing at all.
//
// Jittering here rather than in the projection matrix is deliberate: the Matrix
// struct is not exposed to Lua, so mProj cannot be modified without a C++ change.
// `mView`/`mProj` stay UNJITTERED, which keeps the worldray passes that
// reconstruct rays from mProjInv exactly as they were -- only the rasterisation
// of geometry moves. Fullscreen passes use the identity/worldray vertex shaders
// and are deliberately not jittered.
uniform vec2 taaJitter;

#autovar vec2 taaJitter

void main() {
  VS_BEGIN
  normal = normalize((mWorldIT * vec4(vertex_normal, 0)).xyz);
  vec4 v = vec4(vertex_position, 1.0);
  vec4 wp = mWorld * v;
  pos = wp.xyz;
  gl_Position = mProj * (mView * wp);
  // Offset in clip space so the shift is constant in NDC regardless of depth.
  // Multiplying by gl_Position.w is what makes it a true NDC offset rather than a
  // depth-dependent one.
  gl_Position.xy += taaJitter * gl_Position.w;
  VS_END
}
