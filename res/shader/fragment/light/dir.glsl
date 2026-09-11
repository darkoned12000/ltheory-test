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

/* Dielectric specular intensity (0..1). Splits the diffuse lambert by
 * (1.0 - spec) and adds the GGX approximately-conserving cookTorrance term so
 * DIFFUSE/ICE surfaces get highlights instead of staying fully matte. */
uniform float materialSpec;

uniform sampler2D texNormalMat;
uniform sampler2D texDepth;

/* Sun shadow map (directional). Built in GameView:renderSunShadow with the
 * same ortho Depth32F / distance-from-center machinery as the point lights,
 * with the ortho box centered on the camera in the sun's direction so
 * the visible scene is covered. Only the direct term is killed; ambient stays. */
uniform sampler2D texShadow;
uniform mat4       sShadowProj;
uniform float      sShadowBias;
uniform float      sShadowScale;
uniform float      sShadowRadius;
uniform vec3       sunShadowCenter;

/* Per-sample-pixel-filter shadow test, mirroring point.glsl.
 * Returns 1.0 (lit) .. 0.0 (fully shadowed). */
float PCFSample (sampler2D tex, vec2 uv, float dist, float bias, float radius) {
  if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) return 1.0;
  if (radius < 0.5) {
    float sampleDepth = texture(tex, uv).x;
    return step(dist - bias, sampleDepth);
  }

  vec2 texelSize = 1.0 / vec2(textureSize(tex, 0));
  float lit = 0.0;
  int count = 0;
  int r = int(floor(radius + 0.5));

  for (int y = -r; y <= r; ++y) {
    for (int x = -r; x <= r; ++x) {
      vec2 suv = uv + vec2(float(x), float(y)) * texelSize;
      float sampleDepth = texture(tex, suv).x;
      lit += step(dist - bias, sampleDepth);
      count++;
    }
  }

  return (count > 0) ? clamp(lit / float(count), 0.0, 1.0) : 1.0;
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
    vec3 projCoords = sp.xyz / max(sp.w, 1e-6);
    vec2 suv = (projCoords.xy * 0.5) + 0.5;
    float dist = length(pos - sunShadowCenter);
    float bias = sShadowBias + sShadowScale * dist;
    light *= PCFSample(texShadow, suv, dist, bias, sShadowRadius);
  }

  fragData0 = vec4(light, 1.0);
}
