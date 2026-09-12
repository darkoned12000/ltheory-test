#include fragment
#include deferred
#include gamma

#autovar samplerCube irMap

in vec3 worldOrigin;
in vec3 worldDir;

uniform sampler2D texAlbedo;
uniform sampler2D texDepth;
uniform sampler2D texLighting;

const float ambientLightingScale = 1.0;

void main() {
  vec3 albedo = texture(texAlbedo, uv).xyz;
  vec3 light = texture(texLighting, uv).xyz;
  float depth = max(0.0, texture(texDepth, uv).x);

  vec3 c = albedo * light;

  vec3 ambientColor = vec3(0.0025, 0.0025, 0.0025) * ambientLightingScale;
  vec3 ambientLighting = ambientColor * albedo;

  float fog = 1.0 - exp(-depth / 7000.0);
  float fogScale = 0.0675;

  fog = clamp(fog * fogScale, 0.0, 1.0);

  vec3 wDir = normalize(worldDir);
  vec3 bg = linear(textureLod(irMap, wDir, 3.0 + 6.0 * (1.0 - fog)).xyz);
  c = mix(c, bg, fog);

  c += ambientLighting;

  if (isnan(c.r) || isnan(c.g) || isnan(c.b)) {
    c = vec3(0.0);
  }

  fragData0 = vec4(max(vec3(0.0), c), 1.0);
}
