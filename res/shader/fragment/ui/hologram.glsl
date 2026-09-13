#include fragment
#include math
#include noise

layout(location = 0) out vec4 fragColor;
uniform vec4 color;
uniform float time;

void main() {
  vec3 N = normalize(normal);
  vec3 V = normalize(eye - pos);
  float alpha = 1.0;
  alpha *= uv.x;
  alpha *= 1.0 - abs(dot(N, V));

  // Protect log() against log(0) without capping high-exposure HDR output
  float nVal = noise(vec3(gl_FragCoord.xy, time));
  alpha *= 1.0 - 0.1 * log(max(1e-6, 1.0 - nVal));
  alpha *= 1.0 + 0.2 * sin(radians(180.0) * gl_FragCoord.y);

  vec3 c = 2.0 * color.xyz;
  vec4 outCol = alpha * color.w * vec4(c, 1.0);

  if (isnan(outCol.r) || isnan(outCol.g) || isnan(outCol.b) || isnan(outCol.a)) {
    outCol = vec4(0.0);
  }

  fragColor = max(vec4(0.0), outCol);
}
