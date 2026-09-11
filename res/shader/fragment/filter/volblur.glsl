#include fragment
#include deferred
#include math
#include noise
#include medium

/* Volumetric layer, pass B (full-res, worldray) — fog-nebula Phase 2.
 * Depth-aware 3x3 gather of the half-res volView (aoblur discipline: weight by
 * zBufferL closeness vs the pixel's true depth) then composite over the lit
 * scene, or render one of the `nebula.debug` views.
 *
 *   mode 0 composite    out = scene * T + inscatter   (gather, no silhouette bleed)
 *   mode 1 density      optical depth at this pixel, black->white
 *   mode 2 transmittance T (black = opaque)
 *   mode 3 lighting     inscatter directly
 *   mode 4 steps        grey band for the step budget
 *   mode 5 anchors      plumes only (background suppressed) + half-res cell grid
 */

in vec3 worldOrigin;
in vec3 worldDir;

uniform sampler2D texVol;    /* volView, half-res (inscatter.rgb, T) */
uniform sampler2D texScene;  /* current lit scene, full-res           */
uniform sampler2D texDepth;  /* zBufferL                              */
uniform int       volMode;   /* nebula.debug index - 1                */
uniform float     volGather; /* depth-similarity width                */

void main () {
  float dC = textureLod(texDepth, uv, 0.0).x;
  vec2 voSize = vec2(textureSize(texVol, 0));
  ivec2 pH = ivec2(clamp(floor(gl_FragCoord.xy * 0.5), vec2(0.5), voSize - 0.5));

  if (volMode == 0) {
    vec2 base = floor(gl_FragCoord.xy * 0.5); /* half-res texel index */
    vec4 acc = vec4(0.0);
    float wsum = 0.0;

    // Normalize sky depth to a constant far plane so sky-to-sky taps don't reject each other
    float dC_norm = (dC >= 900000.0) ? 1000000.0 : dC;

    for (int y = -1; y <= 1; ++y) {
      for (int x = -1; x <= 1; ++x) {
        ivec2 p = ivec2(clamp(base + vec2(x, y), vec2(0.5), voSize - 0.5));
        vec4 v = texelFetch(texVol, p, 0);
        vec2 cUv = (vec2(p) + 0.5) / voSize;

        // Sample depth at LOD 0 to prevent blocky downsampled depth grid edges
        float dTap = textureLod(texDepth, cUv, 0.0).x;
        float dTap_norm = (dTap >= 900000.0) ? 1000000.0 : dTap;

        // Relative depth difference to handle large world distances smoothly
        float diff = abs(dTap_norm - dC_norm) / max(1.0, min(dTap_norm, dC_norm));
        float w = exp(-diff * diff * 50.0);

        acc += v * w;
        wsum += w;
      }
    }

    vec4 vol;
    // Fix black silhouette: if weights drop on a depth boundary, fall back to center tap
    if (wsum > 1e-4) {
      vol = acc / wsum;
    } else {
      vol = texelFetch(texVol, pH, 0);
    }

    vec3 scene = texture(texScene, uv).xyz;
    float trans = clamp(vol.a, 0.0, 1.0);
    vec3 inscatter = max(vol.rgb, vec3(0.0));
    fragData0 = vec4(scene * trans + inscatter, 1.0);
    return;
  }

  if (volMode == 1) { /* density */
    if (dC < 1e-4) { fragData0 = vec4(0.0); return; }
    float tCap = (dC >= 900000.0) ? volDist : min(dC, volDist);
    float od = mediumOpticalDepth(worldOrigin, normalize(worldDir), tCap);
    fragData0 = vec4(vec3(clamp(od / volDist, 0.0, 1.0)), 1.0);
    return;
  }
  if (volMode == 2) { /* transmittance */
    fragData0 = vec4(vec3(clamp(texelFetch(texVol, pH, 0).a, 0.0, 1.0)), 1.0);
    return;
  }
  if (volMode == 3) { /* lighting / inscatter */
    fragData0 = vec4(max(texelFetch(texVol, pH, 0).rgb, vec3(0.0)), 1.0);
    return;
  }
  if (volMode == 4) { /* steps */
    fragData0 = vec4(vec3(0.25 + 0.75 * clamp(volSteps / 24.0, 0.0, 1.0)), 1.0);
    return;
  }

  /* mode 5: anchors */
  if (dC < 1e-4) { fragData0 = vec4(0.0); return; }
  float tCap = (dC >= 900000.0) ? volDist : min(dC, volDist);
  vec2 sec = cloudSection(worldOrigin, normalize(worldDir), tCap);
  float od = 0.0;
  float ds = (sec.y - sec.x) / max(1.0, volSteps);
  for (int i = 0; i < 24; ++i) {
    if (float(i) + 0.5 >= volSteps) break;
    od += anchorEnvelope(worldOrigin + normalize(worldDir) * (sec.x + (float(i) + 0.5) * ds)) * ds;
  }
  vec2 g = fract(gl_FragCoord.xy * 0.5);
  float grid = step(0.96, max(g.x, g.y));
  fragData0 = vec4(vec3(clamp(od / 4000.0, 0.0, 1.0)) * 0.85 + vec3(0.15) * grid, 1.0);
}
