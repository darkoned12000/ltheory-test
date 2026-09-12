#include fragment
#include color
#include math

#autovar samplerCube envMap
#autovar samplerCube irMap
#autovar vec3 eye

layout(location = 0) out vec4 fragColor;

float glossToLOD(float gloss) {
  float safeGloss = clamp(gloss, 0.0, 1.0);
  return 8.0 * (pow(2.0, safeGloss) - 1.0);
}

void main() {
  vec3 N = normalize(vertNormal);
  vec3 c = mix(
    mix(vec3(0.2, 0.1, 0.5), vec3(0.5, 0.0, 0.2), max(0.0, -N.y)),
    mix(vec3(0.2, 0.1, 0.5), vec3(0.2, 0.6, 1.0), max(0.0,  N.y)),
    0.5 + 0.5 * N.y);
  c = mix(c, vec3(0.2, 0.2, 0.2), 0.25);

  vec3 V = normalize(pos - eye);
  vec3 R = normalize(reflect(V, N));

  float xDivisor = max(1e-4, sqrt(abs(vertPos.x)));
  float x = abs(0.2 * mod(vertPos.z, xDivisor));
  float alpha =
      0.1 * exp(-32.0 * max(0.0, abs(2.0 * fract(x) - 1.0) - 0.75))
    + 0.9 * exp(-32.0 * max(0.0, abs(2.0 * fract(x) - 1.0) - 0.25));
  float gloss = 0.5 + 0.5 * alpha;
  c = mix(c, sqrt(max(vec3(0.0), c)) * vec3(1.0, 1.5, 2.0), alpha);

  c *= 3.0 * textureLod(irMap, R, glossToLOD(gloss)).xyz;
  c *= max(0.0, uv.x);

  c = max(c, vec3(0.0));
  if (isnan(c.r) || isnan(c.g) || isnan(c.b)) {
    c = vec3(0.0);
  }

  fragColor = vec4(c, 1.0);
  FRAGMENT_CORRECT_DEPTH;
}
