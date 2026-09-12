#include fragment
#include color
#include math

#autovar vec3 eye

layout(location = 0) out vec4 fragColor;

uniform float speed; // Ship speed in m/s from C++/Lua emitter

void main() {
  float dist = length(pos - eye);

  // Compress coordinate space at higher speeds to stretch the mote core
  float speedFactor = max(1.0, speed * 0.02);
  float u = (2.0 * uv.x - 1.0) / speedFactor;

  float alpha = exp(-pow2(2.0 * u));
  alpha *= 0.1;
  alpha *= 1.0 - exp(-8.0 * uv.y);
  alpha *= 1.0 - exp(-8.0 * (1.0 - uv.y));
  alpha *= 1.0 - pow4(1.0 - uv.y);
  alpha *= exp(-4.0 * max(0.0, dist / 1024.0 - 0.8));
  alpha *= 1.0 - exp(-16.0 * max(0.0, dist / 1024.0 - 0.1));

  vec3 c = 1.0 / mix(
    vec3(0.1, 0.5, 1.0),
    vec3(1.0, 0.5, 0.1),
    1.0 - uv.y);

  float lC = max(lum(c), 1e-5);
  c = c / lC;
  c *= sqrt(c);

  fragColor = vec4(c * alpha, 1.0);
}
