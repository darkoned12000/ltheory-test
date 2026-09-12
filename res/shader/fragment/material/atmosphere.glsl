#include fragment
#include math
#include color
#include noise
#include scattering2

#autovar vec3 eye
#autovar vec3 starDir

layout(location = 0) out vec4 fragColor;
uniform vec3 origin;

void main() {
  vec3 L = (length(starDir) > 1e-6) ? normalize(starDir) : vec3(0.0, 1.0, 0.0);
  vec3 N = normalize(normal);

  vec3 eyeRay = pos - eye;
  float depth = max(1e-4, length(eyeRay));
  vec3 V = eyeRay / depth;

  vec4 atmo = atmosphereDefault(V, eye - origin);
  vec4 c = clamp(atmo, vec4(0.0), vec4(100.0));

  if (isnan(c.r) || isnan(c.g) || isnan(c.b) || isnan(c.a)) {
    c = vec4(0.0, 0.0, 0.0, 1.0);
  }

  fragColor = c;
  FRAGMENT_CORRECT_DEPTH;
}
