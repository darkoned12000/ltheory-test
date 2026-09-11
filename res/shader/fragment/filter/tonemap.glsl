#include filter
#include color
#include math
#include noise
#include tonemapping

layout(location = 0) out vec4 fragColor;

uniform float exposure = 1.0;
uniform int texOp = 1;

/* Color Grading Micro-Knobs (Roadmap #14) */
uniform float colorSat      = 1.0;         // 1.0 = neutral
uniform float colorContrast = 1.0;         // 1.0 = neutral
uniform float colorTemp     = 0.0;         // -1.0 (cool) .. 1.0 (warm)
uniform float colorTint     = 0.0;         // -1.0 (green) .. 1.0 (magenta)
uniform vec3  colorLift     = vec3(0.0);   // (0,0,0) = neutral
uniform vec3  colorGamma    = vec3(1.0);   // (1,1,1) = neutral
uniform vec3  colorGain     = vec3(1.0);   // (1,1,1) = neutral

/* Optional Lens Dirt Support */
uniform sampler2D lensDirtTex;
uniform float lensDirtStrength = 0.0;

vec3 applyTonemap(vec3 c) {
  if (texOp == 1) return agxTonemap(c);
  if (texOp == 2) return acesFitted(c);
  if (texOp == 3) return filmicHable(c);
  if (texOp == 4) return pbrNeutral(c);
  return clamp(c, vec3(0.0), vec3(1.0));
}

// Triangular PDF Dither eliminates 8-bit banding across dark space gradients
vec3 ditherTriangular(vec2 uv) {
  float noiseVal = fract(sin(dot(uv, vec2(12.9898, 78.233))) * 43758.5453);
  return vec3((noiseVal - 0.5) / 255.0);
}

void main() {
  vec3 c = max(texture(src, uv).xyz, vec3(0.0));

  // 1. Apply Exposure
  c *= exposure;

  // 2. Lens Dirt Overlay (Applies glass imperfctions to bright HDR light)
  if (lensDirtStrength > 0.0) {
    vec3 dirt = texture(lensDirtTex, uv).xyz;
    c += c * dirt * lensDirtStrength;
  }

  // 3. Linear Space Color Grading
  c = applyColorTint(c, colorTemp, colorTint);
  c = applySaturation(c, colorSat);
  c = applyContrast(c, colorContrast);
  c = applyLiftGammaGain(c, colorLift, colorGamma, colorGain);

  // 4. Tonemap Operator & sRGB Encoding
  c = applyTonemap(c);
  c = encodeSrgb(c);
  c = clamp(c, vec3(0.0), vec3(1.0));

  // 5. High-Frequency Dither
  c += ditherTriangular(uv);
  c = clamp(c, vec3(0.0), vec3(1.0));

  fragColor = vec4(c, 1.0);
}
