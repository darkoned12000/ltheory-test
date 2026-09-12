#include fragment
#include gamma
#include texturing

#autovar samplerCube envMap
#autovar vec3 eye

layout(location = 0) out vec4 fragColor;
uniform sampler2D texDiffuse;
uniform sampler2D texNormal;
uniform sampler2D texSpec;

void main() {
  vec3 N = normalize(normal);
  vec3 uvw = vertPos.xyz * 0.5;

  // Threshold triplanar weight rejection for optimization
  vec3 blend = abs(N);
  blend = max(blend - 0.02, 0.0);
  blend /= (blend.x + blend.y + blend.z + 1e-5);

  vec3 c = sampleTriplanar(texDiffuse, uvw).xyz;
  float spec = sampleTriplanar(texSpec, uvw).x;
  spec = clamp(spec * spec, 0.0, 1.0);

  vec3 eyeRay = pos - eye;
  float eyeDist = max(1e-4, length(eyeRay));
  vec3 V = eyeRay / eyeDist;
  vec3 R = normalize(reflect(V, N));

  vec3 env = textureLod(envMap, R, mix(4.0, 0.0, spec)).xyz;
  c *= max(vec3(0.0), env);

  if (isnan(c.r) || isnan(c.g) || isnan(c.b)) {
    c = vec3(0.0);
  }

  fragColor = vec4(max(vec3(0.0), c), 1.0);
  FRAGMENT_CORRECT_DEPTH;
}
