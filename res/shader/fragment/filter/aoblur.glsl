#include fragment
#include deferred
#include math

/* GTAO pass 3 — depth-aware FULL-RES upsample + bilateral denoise -> aoFull.
 * A plain bilinear upsample of the half-res AO would bleed soft dark halos
 * around silhouettes (ship against starfield, asteroid against space). Gather a
 * 3x3 neighborhood of half-res aoRaw texels, weighting by depth closeness vs
 * the true full-res pixel depth, so the composite never darkens across a depth
 * discontinuity. One pass does both the upsample and the denoise.
 */

uniform sampler2D texAO;     /* aoRaw, half-res           */
uniform sampler2D texDepth;  /* zBufferL, full-res        */
uniform float aoMip;         /* log2(sx/aoSx)             */
uniform float aoBlurScale;   /* depth-similarity width (8/radius^2) */

void main () {
  float dC = textureLod(texDepth, uv, 0.0).x;
  if (dC < 1e-4) { fragData0 = vec4(1.0); return; } /* sky fast-path */

  vec2 aoSize = vec2(textureSize(texAO, 0));
  vec2 base = floor(gl_FragCoord.xy * 0.5); /* half-res texel of this pixel */

  float acc = 0.0;
  float wsum = 0.0;
  for (int y = -1; y <= 1; ++y) {
    for (int x = -1; x <= 1; ++x) {
      ivec2 p = ivec2(clamp(base + vec2(x, y), vec2(0.5), aoSize - 0.5));
      float ao = texelFetch(texAO, p, 0).r;
      vec2 cUv = (vec2(p) + 0.5) / aoSize;
      float dTap = textureLod(texDepth, cUv, aoMip).x;
      float w = exp(-(dTap - dC) * (dTap - dC) * aoBlurScale);
      acc += ao * w;
      wsum += w;
    }
  }
  float ao = (wsum > 1e-6) ? acc / wsum : 1.0;
  fragData0 = vec4(vec3(ao), 1.0);
}