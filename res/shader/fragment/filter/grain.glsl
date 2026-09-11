#include filter
#include noise

layout(location = 0) out vec4 fragColor;

uniform float strength = 1.0;
uniform float time = 0.0;

void main() {
  vec3 c = texture(src, uv).xyz;
  vec2 px = uv * size;

  float g = noise(vec2(px.x, px.y + 97.0 * time));
  g = 0.5 + (g - 0.5) * 0.7;

  // Scale grain attenuation based on local brightness (suppresses grain in bright HDR highlights)
  float luma = dot(c, vec3(0.2126, 0.7152, 0.0722));
  float lumaAtten = 1.0 - smoothstep(0.7, 1.5, luma);

  c += (g - 0.5) * clamp(strength, 0.0, 8.0) * 0.06 * lumaAtten;
  c = max(c, vec3(0.0));

  fragColor = vec4(c, 1.0);
}
