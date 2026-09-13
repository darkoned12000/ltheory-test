#include fragment

layout(location = 0) out vec4 fragColor;
flat in vec4 color;
flat in vec4 widget_a;

const float kRadius = 8.0;

void main() {
  vec2 size = max(vec2(1.0), widget_a.xy);
  vec2 realSize = max(vec2(0.0), size - vec2(64.0));
  vec2 uvp = (2.0 * uv - vec2(1.0));

  float r = min(kRadius, min(size.x, size.y) * 0.5);
  float dist = length(max(vec2(0.0), size * abs(uvp) - (realSize - r))) - r;
  float safeDist = max(0.0, dist);

  float alpha = 0.0;
  alpha += 0.6 * exp(-0.5 * safeDist);
  alpha += 0.4 * exp(-pow(0.3 * safeDist, 0.75));

  vec4 finalColor = alpha * color.w * vec4(2.0 * color.xyz, 1.0);
  if (isnan(finalColor.r) || isnan(finalColor.g) || isnan(finalColor.b) || isnan(finalColor.a)) {
    finalColor = vec4(0.0);
  }

  fragColor = finalColor;
}
