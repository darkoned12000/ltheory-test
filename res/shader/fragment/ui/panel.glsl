#include fragment
#include math

layout(location = 0) out vec4 fragColor;
flat in vec4 color;
flat in vec4 widget_a;
flat in vec4 widget_b;

float dbox(vec2 p, vec2 s, float b) {
  return length(max(vec2(0.0, 0.0), abs(p) - (s - 2.0 * vec2(b, b)))) - b;
}

void main() {
  float padding = widget_a.x;
  vec2 size = max(vec2(1e-4), widget_a.yz);
  float innerAlpha = widget_a.w;
  float bevel = widget_b.x;
  vec3 c;
  c = color.xyz * (1.25 - 0.5 * uv.y);
  float x = size.x * (2.0 * uv.x - 1.0);
  float y = size.y * (2.0 * uv.y - 1.0);

  float d = dbox(vec2(x, y), size + bevel - 2.0 * padding, bevel);
  float safeD = max(0.0, d);
  float k = exp(-safeD);
  float mult = 0.0;

  /* Inner opacity. */ {
    mult += innerAlpha * k;
  }

  /* Shadow. */ {
    mult += 0.75 * saturate(exp(-pow(max(1e-5, 0.2 * safeD), 0.75)) - k);
  }

  mult *= color.w;
  mult = saturate(mult);

  /* Gradient. */ {
    c *= 0.8 + 0.4 * exp(-2.0 * uv.y);
  }

  c += 0.3 * vec3(0.1, 0.5, 1.0) * exp(-8.0 * length(uv - vec2(0.5, 0.0)));
  c = mix(c, vec3(0.005, 0.005, 0.005), 1.0 - exp(-2.0 * safeD));

  vec4 outCol = vec4(c, mult);
  if (isnan(outCol.r) || isnan(outCol.g) || isnan(outCol.b) || isnan(outCol.a)) {
    outCol = vec4(0.0);
  }

  fragColor = max(vec4(0.0), outCol);
}
