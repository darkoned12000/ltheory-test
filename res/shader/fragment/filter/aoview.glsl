#include fragment
#include deferred
#include math

/* GTAO pass 1 — per-pixel view ray + N·V at half-res.
 * zBufferL (linear eye distance) read at aoMip (log2(sx/aoSx)) gives the free
 * downsampled depth; texNormalMat is the full-res G-buffer normal+rough+mat.
 *
 * We store the pixel's UNIT VIEW RAY (not position) so pass 2 can rebuild any
 * tap's view-space point as `ray * depth` with NO per-tap matrix inverse —
 * GTAO's cheap trick: rays are rotation-invariant and depth is linear distance.
 */

#autovar mat4 mView
uniform mat4 mView;

in vec3 worldOrigin;
in vec3 worldDir;

uniform sampler2D texDepth;     /* zBufferL                */
uniform sampler2D texNormalMat; /* buffer1 (normal+rough+mat) */
uniform float aoMip;            /* log2(sx/aoSx)           */

void main () {
  vec4 normalMat = texture(texNormalMat, uv);
  float dist = textureLod(texDepth, uv, aoMip).x;

  /* Camera is the view-space origin; worldDir is a direction (camera at
   * worldOrigin), so a pure rotation (mat3 of mView) takes it to view space.
   * worldDir interpolated across the fullscreen quad = the per-pixel ray. */
  vec3 viewDir = mat3(mView) * normalize(worldDir);

  /* N·V for the blur/upsample gating (V points from the surface to the camera).
   * Sky (dist ≈ 0) is forced to 1.0 so blur never darkens it. */
  vec3 Nw = decodeNormal(normalMat.xy);
  float ndv = clamp(dot(mat3(mView) * Nw, -viewDir), 0.0, 1.0);

  fragData0 = vec4(viewDir, (dist > 1e-4) ? ndv : 1.0);
}