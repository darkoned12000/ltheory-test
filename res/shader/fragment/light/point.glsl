#include fragment
#include deferred
#include math
#include pbr


in vec3 worldOrigin;
in vec3 worldDir;

uniform vec3 lightColor;
uniform vec3 lightPos;

/* Dielectric specular intensity (0..1); shared with light/dir. Splits the
 * diffuse Lambert term and adds the GGX cookTorrance spec, so DIFFUSE/ICE
 * surfaces catch highlights from nearby lights. */
uniform float materialSpec;

uniform sampler2D texNormalMat;
uniform sampler2D texDepth;
uniform sampler2D texShadow;

// Shadow tuning (set per-light by Lua):
//   sShadowProj  : ortho view-proj used to render the shadow map. Projects a
//                  world position into the map's [0,1] UV space. Built from an
//                  ortho frustum centered on the light and aligned with the
//                  light->camera direction so most geometry lands near +Z.
//   sShadowBias  : constant PCF bias (acne/tearing prevention).
//   sShadowScale : distance-dependent bias scale (softness vs acne tradeoff).
//   sShadowRadius: PCF radius in texels.
uniform mat4  sShadowProj;
uniform float sShadowBias;
uniform float sShadowScale;
uniform float sShadowRadius;

const float kMinDistance = 0.0001;
const float kPointLightMult = 16.0;

/* Rotated Poisson Disk distribution (8 samples) for soft shadow filtering. */
const vec2 kPoissonDisk8[8] = vec2[8](
  vec2(-0.7071,  0.7071),
  vec2(-0.0000, -0.8750),
  vec2( 0.5303,  0.5303),
  vec2(-0.6250, -0.2165),
  vec2( 0.3750, -0.6495),
  vec2( 0.7071,  0.0000),
  vec2(-0.2500,  0.4330),
  vec2( 0.1250,  0.2165)
);

float PCFSamplePoisson (sampler2D tex, vec2 uv, float dist, float bias, float radius) {
  if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) return 1.0;
  if (radius < 0.5) return step(dist - bias, texture(tex, uv).x);

  vec2 ts = (radius / vec2(textureSize(tex, 0)));
  float lit = 0.0;

  // Pseudo-random per-pixel rotation angle to break up shadow grid aliasing
  float angle = fract(sin(dot(uv, vec2(12.9898, 78.233))) * 43758.5453) * 6.28318530718;
  float cosA = cos(angle);
  float sinA = sin(angle);
  mat2 rot = mat2(cosA, -sinA, sinA, cosA);

  for (int i = 0; i < 8; ++i) {
    vec2 offset = (rot * kPoissonDisk8[i]) * ts;
    lit += step(dist - bias, texture(tex, uv + offset).x);
  }
  return saturate(1.0 - (lit * 0.125));
}

void main () {
  vec4 normalMat = texture(texNormalMat, uv);
  float depth = max(0.0, texture(texDepth, uv).x);
  vec3 N = decodeNormal(normalMat.xy);
  float rough = clamp(normalMat.z, 0.0, 1.0);
  float mat = normalMat.w;

  if (mat == Material_NoShade) {
    fragData0 = vec4(0.0, 0.0, 0.0, 1.0);
    return;
  }

  vec3 wDir = normalize(worldDir);
  vec3 p = worldOrigin + depth * wDir;

  vec3 L = lightPos - p;
  float dist = length(L);
  vec3 Ld = (dist > 1e-6) ? L / dist : vec3(0.0, 1.0, 0.0);

  float NdL = dot(N, Ld);

  // Early-out: skip shadow texture sampling completely for back-facing surfaces
  if (NdL <= 0.0 && mat != Material_Metal) {
    fragData0 = vec4(0.0, 0.0, 0.0, 1.0);
    return;
  }

  vec4 sp = sShadowProj * vec4(p, 1.0);
  vec2 suv = (sp.xy * 0.5) + 0.5;

  float shadowAmt = 1.0;
  float bias = sShadowBias + sShadowScale * dist;
  shadowAmt = PCFSamplePoisson(texShadow, suv, dist, bias, sShadowRadius);

  vec3 light = vec3(0.0);

  if (mat == Material_Diffuse || mat == Material_Ice) {
    float Lmag = 1.0 / max(kMinDistance, dist);
    float NdLc = saturate(NdL);
    light += lightColor * (NdLc * (1.0 - materialSpec) + cookTorrance(Ld, p, N, rough, materialSpec)) * Lmag;
  }
  else if (mat == Material_Metal) {
    float Lt = cookTorrance(Ld, p, N, rough, 1.0);
    light += lightColor * Lt / max(kMinDistance, dist);
  }

  light *= shadowAmt * kPointLightMult;

  if (isnan(light.r) || isnan(light.g) || isnan(light.b)) {
    light = vec3(0.0);
  }

  fragData0 = vec4(max(vec3(0.0), light), 1.0);
}
