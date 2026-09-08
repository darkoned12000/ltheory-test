#include fragment
#include math


layout(location = 0) out vec4 fragColor;
flat in vec4 color;
flat in vec4 widget_a;
flat in vec4 widget_b;

void main() {
  vec2 p1 = widget_a.xy;
  vec2 p2 = widget_a.zw;
  vec2 origin = widget_b.xy;
  vec2 size = widget_b.zw;
  vec2 uvp = uv;
  vec3 c = color.xyz;

  vec2 tp = uvp * size + origin;
  vec2 toPoint = tp - p1;
  vec2 dir = p2 - p1;
  vec2 n = normalize(dir);
  float l = length(dir);
  if (l <= 1e-6) {
    discard;
    return;
  }

  float projLength = clamp(dot(n, toPoint), 0.0, l);
  vec2 proj = n * projLength;
  float d = length(toPoint - proj);
  float t = saturate(1.0 - projLength / l);
  float alpha = 0.0;
  alpha += 0.8 * exp(-2.0 * max(0.0, d - 0.5));
  alpha += 0.2 * exp(-pow(0.2 * d, 0.75));

  alpha *= exp(-2.0 * (1.0 - t));
  fragColor = alpha * color.w * vec4(c, 1.0);
}
