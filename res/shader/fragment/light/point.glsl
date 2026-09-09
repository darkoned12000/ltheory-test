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

/* Per-sample-pixel-filter shadow test. texShadow stores, per texel, the
 * nearest occluder's distance-from-light (from the ortho shadow render). A
 * fragment is in shadow when that occluder is closer to the light than the
 * fragment itself. Returns 1.0 (lit) .. 0.0 (fully shadowed). */
float PCFSample (sampler2D tex, vec2 uv, float dist, float bias, float radius) {
  if (radius < 0.5) return 1.0;
  vec2 ts = textureSize(tex, 0);
  float lit = 0.0;
  int count = 0;
  for (int y = -int(radius); y <= int(radius); ++y) {
    for (int x = -int(radius); x <= int(radius); ++x) {
      vec2 off = vec2(float(x), float(y)) * radius * ts;
      uv += off;
      // shadow when the occluder is closer to the light than the fragment:
      // sd < dist  -> in shadow. Subtract bias so an occluder must be clearly
      // inside to count, which kills acne/tearing near grazing angles.
      lit += step(dist - bias, texture(tex, uv).x);
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

  // Reconstruct the fragment's world position from camera space (eye + ray*depth).
  vec3 p = worldOrigin + depth * normalize(worldDir);

  vec3 L = lightPos - p;
  float dist = length(L);
  vec3 Ld = normalize(L);

  // Map the fragment into the shadow map's UV space.
  vec4 sp = sShadowProj * vec4(p, 1.0);
  vec2 suv = (sp.xy * 0.5) + 0.5;

  float shadowAmt = 1.0;
  if (mat != Material_NoShade) {
    float bias = sShadowBias + sShadowScale * dist;
    shadowAmt = PCFSample(texShadow, suv, dist, bias, sShadowRadius);
  }

  vec3 light = vec3(0.0);

  if (mat == Material_Diffuse || mat == Material_Ice) {
    float NdL = dot(N, Ld);
    if (NdL > 0.0) {
      float Lmag = 1.0 / max(kMinDistance, dist);
      float NdLc = saturate(NdL);
      light += lightColor * (NdLc * (1.0 - materialSpec) + cookTorrance(Ld, p, N, rough, materialSpec)) * Lmag;
    }
  }

  else if (mat == Material_Metal) {
    float Lt = cookTorrance(Ld, p, N, rough, 1.0);
    light += lightColor * Lt / max(kMinDistance, dist);
  }

  light *= shadowAmt * kPointLightMult;

  fragData0 = vec4(light, 1.0);
}
