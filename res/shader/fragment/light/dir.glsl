#include fragment
#include deferred
#include math
#include pbr

#autovar vec3 starDir

/* Directional sunlight. Deferred full-screen accumulation pass, additive on
 * top of the ambient (`light/global`) pass. `starDir` is the System's sun
 * direction (surface -> star), uploaded as an autovar during world render;
 * the nebula skybox handles the visible disc, so Material_NoShade pixels are
 * intentionally left untouched (and excluded from the shadow test). */
in vec3 worldOrigin;
in vec3 worldDir;

uniform vec3 lightColor;

/* Dielectric specular intensity (0..1). Simply splits the diffuse lambert by
 * (1.0 - spec) and adds the GGX approximately-conserving cookTorrance term so
 * DIFFUSE/ICE surfaces get highlights instead of staying fully matte. */
uniform float materialSpec;

uniform sampler2D texNormalMat;
uniform sampler2D texDepth;

/* Sun shadow map (directional). Built in GameView:renderSunShadow with the
 * same ortho Depth32F / distance-from-center machinery as the point lights,
 * with the ortho box centered on the camera in the sun's direction direction so
 * the visible scene is covered. Only the direct term is killed; ambient stays. */
uniform sampler2D texShadow;
uniform mat4       sShadowProj;
uniform float      sShadowBias;
uniform float      sShadowScale;
uniform float      sShadowRadius;
uniform vec3       sunShadowCenter;

/* Per-sample-pixel-filter shadow test, mirroring point.glsl: texShadow stores
 * per-texel occluder distance from the shadow-camera origin (== sunShadowCenter)
 * in the same radial metric, so a fragment is shadowed when an occluder sits
 * closer to that origin. Returns 1.0 (lit) .. 0.0 (fully shadowed). */
float PCFSample (sampler2D tex, vec2 uv, float dist, float bias, float radius) {
  if (radius < 0.5) return 1.0;
  vec2 ts = textureSize(tex, 0);
  float lit = 0.0;
  int count = 0;
  for (int y = -int(radius); y <= int(radius); ++y) {
    for (int x = -int(radius); x <= int(radius); ++x) {
      vec2 suv = uv + vec2(float(x), float(y)) * radius * ts;
      lit += step(dist - bias, texture(tex, suv).x);
      count++;
    }
  }
  return (count > 0) ? saturate(1.0 - (lit / float(count))) : 1.0;
}

void main () {
  vec4 normalMat = texture(texNormalMat, uv);
  float depth = texture(texDepth, uv).x;
  vec3 N = decodeNormal(normalMat.xy);
  float rough = normalMat.z;
  float mat = normalMat.w;
  vec3 pos = worldOrigin + depth * normalize(worldDir);

  vec3 L = normalize(starDir);
  vec3 light = vec3(0.0);

  if (mat == Material_Diffuse || mat == Material_Ice) {
    float NdL = max(dot(N, L), 0.0);
    light += lightColor * (NdL * (1.0 - materialSpec) + cookTorrance(L, pos, N, rough, materialSpec));
  }
  else if (mat == Material_Metal) {
    float Lt = cookTorrance(L, pos, N, rough, 1.0);
    light += lightColor * Lt;
  }

  if (mat != Material_NoShade) {
    vec4 sp = sShadowProj * vec4(pos, 1.0);
    vec2 suv = (sp.xy * 0.5) + 0.5;
    float dist = length(pos - sunShadowCenter);
    float bias = sShadowBias + sShadowScale * dist;
    light *= PCFSample(texShadow, suv, dist, bias, sShadowRadius);
  }

  fragData0 = vec4(light, 1.0);
}