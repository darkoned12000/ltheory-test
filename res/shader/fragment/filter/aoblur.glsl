#include fragment
#include deferred
#include math

/* GTAO pass 3 — depth-aware FULL-RES upsample + bilateral denoise -> aoFull. */

uniform sampler2D texAO;     /* aoRaw, half-res           */
uniform sampler2D texDepth;  /* zBufferL, full-res        */
uniform float aoMip;         /* log2(sx/aoSx)             */
uniform float aoBlurScale;   /* depth-similarity width (8/radius^2) */

void main () {
  float dC = textureLod(texDepth, uv, 0.0).x;
  if (dC < 1e-4 || dC >= 900000.0) { fragData0 = vec4(1.0); return; } /* sky fast-path */

  vec2 aoSize = vec2(textureSize(texAO, 0));
  ivec2 base = ivec2(clamp(floor(gl_FragCoord.xy * 0.5), vec2(0.5), aoSize - 0.5));

  float acc = 0.0;
  float wsum = 0.0;
  for (int y = -1; y <= 1; ++y) {
    for (int x = -1; x <= 1; ++x) {
      ivec2 p = ivec2(clamp(vec2(base) + vec2(x, y), vec2(0.5), aoSize - 0.5));
      float ao = texelFetch(texAO, p, 0).r;
      vec2 cUv = (vec2(p) + 0.5) / aoSize;

      // Sample tap depth at LOD 0.0 to prevent mipmap depth bleeding
      float dTap = textureLod(texDepth, cUv, 0.0).x;
      float dTap_norm = (dTap >= 900000.0) ? 1000000.0 : dTap;
      float dC_norm   = (dC   >= 900000.0) ? 1000000.0 : dC;

      float diff = dTap_norm - dC_norm;
      float w = exp(-diff * diff * aoBlurScale);
      acc += ao * w;
      wsum += w;
    }
  }

  // Fall back to the center half-res tap if all 9 tap weights fail on a sharp edge
  float ao = (wsum > 1e-4) ? (acc / wsum) : texelFetch(texAO, base, 0).r;
  fragData0 = vec4(vec3(ao), 1.0);
}
