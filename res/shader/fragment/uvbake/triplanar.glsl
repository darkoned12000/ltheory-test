#include fragment
#include texturing
#include math

layout(location = 0) out vec4 fragColor;

uniform sampler2D src;
uniform float     texScale; /* Scaled dynamically per asteroid size class */

void main() {
  float activeScale = max(0.01, texScale);
  vec3 uvw = sqrt(activeScale / 32.0) * abs(vertPos.xyz);

  // Multi-frequency detail sampling
  vec3 c = sampleTriplanar(src, uvw).xyz;
  c *= pow2(sampleTriplanar(src, uvw * 4.0).xyz);
  c = sqrt(c);

  fragColor = vec4(c, 1.0);
}
