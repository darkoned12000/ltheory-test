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

/* Screen-space ambient occlusion (GTAO). texAO is the full-res aoFull when the
 * AO chain ran, or a 1x1 white fallback; aoStrength (0 = off) scales the effect
 * so the off-frame is bit-identical. aoShow forces pure AO for preview/tuning. */
uniform sampler2D texAO;
uniform float aoStrength;
uniform float aoShow;

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

  float ao = texture(texAO, uv).r;
  float aoF = mix(1.0, ao, aoStrength);

  if (aoShow > 0.5) {
    fragData0 = vec4(vec3(aoF), 1.0);   /* preview: pure AO */
    return;
  }

  if (mat == Material_Diffuse || mat == Material_Ice) {
    light += (linear(textureLod(irMap, N, 8.0).xyz) * envScale + fill) * aoF;
  }

  else if (mat == Material_Metal) {
    #ifdef HIGHQ
      light += linear(textureLod(irMap, R, roughnessToLOD(rough)).xyz) * envScale;
    #else
      light += linear(texture(envMap, R).xyz) * envScale;
    #endif
    light += fill * 0.6;
    /* Env reflection on plating already carries its own occlusion cues —
     * metal takes only 15% of the AO factor so hulls don't muddy. */
    light *= mix(1.0, ao, 0.15 * aoStrength);
  }

  else if (mat == Material_NoShade) {
    light += vec3(1.0);
  }

  fragData0 = vec4(light, 1.0);
}
