#include fragment
#include deferred
#include math
#include pbr

#autovar vec3 starDir

in vec3 worldOrigin;
in vec3 worldDir;

uniform vec3 lightColor;
uniform float materialSpec;

uniform sampler2D texNormalMat;
uniform sampler2D texDepth;
uniform sampler2D texShadow;
uniform mat4       sShadowProj;
uniform float      sShadowBias;
uniform float      sShadowScale;
uniform float      sShadowRadius;
uniform vec3       sunShadowCenter;

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

  float angle = fract(sin(dot(uv, vec2(12.9898, 78.233))) * 43758.5453) * 6.28318530718;
  float cosA = cos(angle);
  float sinA = sin(angle);
  mat2 rot = mat2(cosA, -sinA, sinA, cosA);

  for (int i = 0; i < 8; ++i) {
    vec2 offset = (rot * kPoissonDisk8[i]) * ts;
    lit += step(dist - bias, texture(tex, uv + offset).x);
  }

  return saturate(lit * 0.125);
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
  vec3 pos = worldOrigin + depth * wDir;

  float starLen = length(starDir);
  vec3 L = (starLen > 1e-6) ? starDir / starLen : vec3(0.0, 1.0, 0.0);
  vec3 light = vec3(0.0);

  float NdL = max(dot(N, L), 0.0);

  if (mat == Material_Diffuse || mat == Material_Ice) {
    light += lightColor * (NdL * (1.0 - materialSpec) + cookTorrance(L, pos, N, rough, materialSpec));
  }
  else if (mat == Material_Metal) {
    float Lt = cookTorrance(L, pos, N, rough, 1.0);
    light += lightColor * Lt;
  }

  vec4 sp = sShadowProj * vec4(pos, 1.0);
  vec3 projCoords = sp.xyz / max(sp.w, 1e-6);
  vec2 suv = (projCoords.xy * 0.5) + 0.5;
  float dist = length(pos - sunShadowCenter);
  float bias = sShadowBias + sShadowScale * dist;
  light *= PCFSamplePoisson(texShadow, suv, dist, bias, sShadowRadius);

  if (isnan(light.r) || isnan(light.g) || isnan(light.b)) {
    light = vec3(0.0);
  }

  fragData0 = vec4(max(vec3(0.0), light), 1.0);
}
