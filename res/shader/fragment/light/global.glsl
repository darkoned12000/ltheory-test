#include fragment
#include color
#include deferred
#include gamma
#include math

#autovar samplerCube irMap
#autovar vec3 eye
#autovar vec3 starDir

in vec3 worldOrigin;
in vec3 worldDir;

uniform vec3 lightColor;
uniform vec3 lightPos;
uniform vec3 sunColor;
uniform float sunFill;
uniform float envScale;

uniform sampler2D texNormalMat;
uniform sampler2D texDepth;
uniform sampler2D texAO;
uniform float aoStrength;
uniform float aoShow;
uniform float fillOcclude;

float roughnessToLOD (float r) {
  float safeR = clamp(r, 0.0, 1.0);
  return 8.0 * (pow(2.0, safeR) - 1.0);
}

void main () {
  vec4 normalMat = texture(texNormalMat, uv);
  float depth = max(0.0, texture(texDepth, uv).x);
  vec3 N = decodeNormal(normalMat.xy);
  float rough = clamp(normalMat.z, 0.0, 1.0);
  float mat = normalMat.w;

  vec3 wDir = normalize(worldDir);
  vec3 pos = worldOrigin + depth * wDir;
  vec3 V = normalize(pos - eye);
  vec3 R = normalize(reflect(V, N));

  float starLen = length(starDir);
  vec3 Ls = (starLen > 1e-6) ? starDir / starLen : vec3(0.0, 1.0, 0.0);

  float NdL = 0.5 + 0.5 * max(dot(N, Ls), 0.0);
  vec3 fill = sunColor * (sunFill * NdL);

  vec3 light = vec3(0.0);

  float ao = texture(texAO, uv).r;
  float aoF = mix(1.0, ao, aoStrength);
  float aoFill = mix(1.0, ao, aoStrength * fillOcclude);

  if (aoShow > 0.5) {
    if (mat == Material_NoShade)
      fragData0 = vec4(vec3(1.0), 1.0);
    else
      fragData0 = vec4((linear(textureLod(irMap, N, 8.0).xyz) * envScale) * aoF + fill * aoFill, 1.0);
    return;
  }

  if (mat == Material_Diffuse || mat == Material_Ice) {
    light += (linear(textureLod(irMap, N, 8.0).xyz) * envScale) * aoF + fill * aoFill;
  }

  else if (mat == Material_Metal) {
    #ifdef HIGHQ
      light += linear(textureLod(irMap, R, roughnessToLOD(rough)).xyz) * envScale;
    #else
      light += linear(texture(envMap, R).xyz) * envScale;
    #endif
    light += fill * 0.6;

    // Decoupled Specular Occlusion calculation
    float NdV = max(0.0, dot(N, -V));
    float specAO = clamp(pow2(NdV + ao) - 1.0 + NdV, 0.0, 1.0);
    light *= mix(1.0, specAO, 0.15 * aoStrength);
  }

  else if (mat == Material_NoShade) {
    light += vec3(1.0);
  }

  if (isnan(light.r) || isnan(light.g) || isnan(light.b)) {
    light = vec3(0.0);
  }

  fragData0 = vec4(max(vec3(0.0), light), 1.0);
}
