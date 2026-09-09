#include fragment
#include color
#include deferred
#include gamma
#include math

#autovar samplerCube irMap
#autovar vec3 eye
#autovar vec3 starDir
#autovar vec3 sunColor
#autovar float sunFill

in vec3 worldOrigin;
in vec3 worldDir;

uniform vec3 lightColor;
uniform vec3 lightPos;

/* Warm hemisphere fill from the sun, so shadowed sides of asteroids/ships/
 * planets read as dim sun-facing rather than pure black. `starDir` is the
 * autovar the System pushes each frame. */
uniform vec3 sunColor;
uniform float sunFill;

/* IBL intensity: scales the irMap/envMap ambient so the dark side of a ring
 * can be lifted without touching the sun fill. Set from `lighting.ambientEnv`. */
uniform float envScale;

uniform sampler2D texNormalMat;
uniform sampler2D texDepth;

float roughnessToLOD (float r) {
  return 8.0 * (pow(2.0, r) - 1.0);
}

void main () {
  vec4 normalMat = texture(texNormalMat, uv);
  float depth = texture(texDepth, uv).x;
  vec3 N = decodeNormal(normalMat.xy);
  float rough = normalMat.z;
  float mat = normalMat.w;
  vec3 pos = worldOrigin + depth * normalize(worldDir);
  vec3 V = normalize(pos - eye);
  vec3 R = normalize(reflect(V, N));

  /* Cosine-weighted hemisphere toward the sun (0.5 at grazing, 1.0 facing). */
  float NdL = 0.5 + 0.5 * max(dot(N, normalize(starDir)), 0.0);
  vec3 fill = sunColor * (sunFill * NdL);

  vec3 light = vec3(0.0);

  if (mat == Material_Diffuse || mat == Material_Ice) {
    light += linear(textureLod(irMap, N, 8.0).xyz) * envScale + fill;
  }

  else if (mat == Material_Metal) {
    #ifdef HIGHQ
      light += linear(textureLod(irMap, R, roughnessToLOD(rough)).xyz) * envScale;
    #else
      light += linear(texture(envMap, R).xyz) * envScale;
    #endif
    light += fill * 0.6;
  }

  else if (mat == Material_NoShade) {
    light += vec3(1.0);
  }

  fragData0 = vec4(light, 1.0);
}
