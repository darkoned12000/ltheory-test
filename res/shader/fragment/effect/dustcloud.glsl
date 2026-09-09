#include fragment
#include gamma
#include math
#include noise
#include color

#autovar samplerCube irMap
#autovar vec3 starDir
#autovar vec3 sunColor

layout(location = 0) out vec4 fragColor;
uniform sampler2D texDust;

uniform vec3 sunColor;

void main() {
  vec3 V = pos - eye;
  float dist = length(V) / 1024.0;
  vec4 bg = textureLod(irMap, V, 2.0);
  vec3 c = mix(vec3(0.2), mix(bg.xyz, 0.75 * sqrt(bg.xyz), 0.25), 0.8);
  /* Dust lanes glow when their billboard looks back toward the star. */
  c += sunColor * (0.16 * (0.5 + 0.5 * saturate(dot(normalize(V), normalize(starDir)))));
  float a = texture(texDust, 0.5 + 0.5 * uv).x;
  a *= saturate((1.0 - dist) / 0.25);
  a *= saturate(dist / 0.25);
  a *= 0.75;
  a = saturate(a);
  a *= a;
  fragColor = vec4(linear(c), a);
  FRAGMENT_CORRECT_DEPTH;
}
