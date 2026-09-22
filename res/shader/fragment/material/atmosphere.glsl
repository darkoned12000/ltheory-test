#include fragment
#include math
#include color
#include noise
#include scattering2

#autovar vec3 eye
#autovar vec3 starDir
#autovar vec3 sunColor

layout(location = 0) out vec4 fragColor;
uniform vec3 origin;
uniform vec3 sunColor;
uniform float atmoGlow;

void main() {
  vec3 L = (length(starDir) > 1e-6) ? normalize(starDir) : vec3(0.0, 1.0, 0.0);
  vec3 N = normalize(normal);

  vec3 eyeRay = pos - eye;
  float depth = max(1e-4, length(eyeRay));
  vec3 V = eyeRay / depth;

  // scattering2 is a SECOND, hardcoded sun (iSun=22, its own starColor) and
  // ignores render.sun.*. Gate its colour with the engine sun so 'Sun Light'
  // off darkens the atmosphere mesh too (the transmittance/alpha is kept).
  float sunOn = clamp(max(max(sunColor.r, sunColor.g), sunColor.b), 0.0, 1.0);
  vec4 atmo = atmosphereDefault(V, eye - origin);
  atmo.xyz *= sunOn * atmoGlow;
  vec4 c = clamp(atmo, vec4(0.0), vec4(100.0));

  if (isnan(c.r) || isnan(c.g) || isnan(c.b) || isnan(c.a)) {
    c = vec4(0.0, 0.0, 0.0, 1.0);
  }

  fragColor = c;
  FRAGMENT_CORRECT_DEPTH;
}
