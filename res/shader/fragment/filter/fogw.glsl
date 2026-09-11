#include fragment
#include math

in vec3 worldDir;

layout(location = 0) out vec4 fragColor;

uniform sampler2D src;
uniform sampler2D texDepth;

uniform float fogDensity;
uniform vec3  fogColor;
uniform float fogTint;
uniform float fogMax;

void main() {
  vec3 c = texture(src, uv).xyz;
  float dist = texture(texDepth, uv).r;
  /* The skybox writes a real linear depth into zBufferL via setDepth()
   * (gl_FragDepth is masked, but the G-buffer lane is not), equal to
   * length(farPlane*vertPos - eye) with farPlane = 1.0e6 (common.glsl).
   * So sky pixels read dist >= ~1e6 — gate them out at 950k so the
   * starfield/nebula stay crisp and only real geometry hazes.  The 1e-4
   * case is belt-and-suspenders for any cleared (zero-depth) region. */
  float fogF = dist >= 950000.0 || dist < 1e-4 ? 0.0
             : 1.0 - exp(-fogDensity * dist);
  fogF = min(fogF, fogMax);
  /* Aerial perspective: haze blends toward the nebula color actually behind
   * this pixel (sampled along the world view ray), tinted slightly toward
   * the user color so it still reads as a deliberate "fog" tone. */
  vec3 dir = normalize(worldDir);
  vec3 bg = mix(texture(envMap, dir).xyz, fogColor, fogTint);
  fragColor = vec4(mix(c, bg, fogF), 1.0);
}
