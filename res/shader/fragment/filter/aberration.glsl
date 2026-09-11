#include filter
#include math
#include color
#include noise

layout(location = 0) out vec4 fragColor;

uniform float strength;
uniform float dispersionAmount; // Replaces hardcoded 'a' (default: 0.0002)
uniform float aspect;           // Screen aspect ratio (screen.x / screen.y)

void main() {
  vec3 cc = texture(src, uv).xyz;
  vec3 c = cc;
  vec3 tw = vec3(1.0);

  // Aspect-ratio corrected center vector
  vec2 dir = uv - 0.5;
  dir.x *= aspect;

  // Non-linear radial dispersion falloff
  dir = sign(dir) * pow2(dir);
  float dispScale = (dispersionAmount > 0.0) ? dispersionAmount : 0.0002;
  dir = dispScale * normalize(dir + vec2(1e-6));
  dir.x /= aspect; // Return to normalized UV space

  vec2 uvp = uv;
  for (int i = -8; i <= 8; ++i) {
    vec3 w = pow(vec3(1.5, 1.00, 0.50), vec3(float(i) / 4.0));
    c += w * texture(src, uvp + float(i) * dir).xyz;
    tw += w;
  }
  c /= tw;

  // Safe luminance normalization (prevents 0.0 / 0.0 NaN crashes on black pixels)
  float lC = max(lum(c), 1e-5);
  c = lum(cc) * (c / lC);
  c = mix(cc, c, strength);

  fragColor = vec4(c, 1.0);
}
