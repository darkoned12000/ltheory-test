#include fragment
#include deferred
#include gamma
#include texturing
#include color
#include math
#include fog

#autovar samplerCube irMap
#autovar samplerCube envMap
#autovar vec3 eye

uniform float scale;
uniform float edgeDarkness;
uniform sampler2D texDiffuse;
uniform sampler2D texDiffuseUV;
uniform sampler2D texPaintUV;
uniform sampler2D texNormal;
uniform sampler2D texSpec;

float glossToLOD(float gloss) {
  float safeGloss = clamp(gloss, 0.0, 1.0);
  return 8.0 * (pow(2.0, safeGloss) - 1.0);
}

void main() {
  vec3 N = normalize(normal);
  float safeScale = max(0.0, scale);
  vec3 uvw = sqrt(safeScale / 32.0) * abs(vertPos.xyz);
  vec3 diff = texture(texDiffuseUV, uv).xyz;

  float normalDiff = max(0.0, length(N - normal));
  diff *= mix(vec3(1.0 - edgeDarkness), vec3(1.0), exp(-sqrt(1024.0 * normalDiff)));

  float gloss = clamp(1.0 - sampleTriplanar(texSpec, uvw).x, 0.0, 1.0);

  vec3 eyeRay = pos - eye;
  float eyeDist = max(1e-4, length(eyeRay));
  vec3 V = eyeRay / eyeDist;
  vec3 R = normalize(reflect(V, N));

  vec4 paint = texture(texPaintUV, uv);

  vec3 c = diff;
  c = mix(c, paint.xyz, paint.w);

  #ifdef HIGHQ
    c *= textureLod(irMap, R, glossToLOD(gloss)).xyz;
  #else
    c *= texture(envMap, R).xyz;
  #endif

  c = mix(c, textureLod(envMap, V, 4.0).xyz, getFog());
  c = clamp(c, vec3(0.0), vec3(1.0));

  if (isnan(c.r) || isnan(c.g) || isnan(c.b)) {
    c = vec3(0.0);
  }

  FRAGMENT_CORRECT_DEPTH;

  setAlbedo(c);
  setAlpha(1.0);
  setDepth();
  setNormal(N);
  setRoughness(gloss);
  setMaterial(Material_Metal);
}
