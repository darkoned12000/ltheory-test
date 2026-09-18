#include fragment

layout(location = 0) out vec4 fragColor;

// Endpoints + width, in pixel space (matches vertex/ui.glsl viewport quad).
uniform vec2 p1;        // A : start of edge segment
uniform vec2 p2;        // B : end of edge segment
uniform float width;    // line width (px)
uniform float dash;     // dash period (px); < 0.5 = solid line
uniform float flow;     // animation phase (time * speed); dots drift toward B
uniform vec4 color;

void main() {
  vec2 fragPos = pos.xy;   // pixel space (from vertex/ui.glsl viewport quad)

  vec2 seg = p2 - p1;
  float segLen = max(length(seg), 1e-6);
  float u = clamp(dot(fragPos - p1, seg) / (segLen * segLen), 0.0, 1.0);
  float d = length(fragPos - (p1 + seg * u));

  float alpha = 0.0;
  alpha += 0.8 * exp(-2.0 * max(0.0, d - 0.5));
  alpha += 0.2 * exp(-pow(max(1e-5, 0.2 * d), 0.75));

  // Dash mask (square wave along the segment); solid when dash < 0.5.
  // flow shifts the pattern toward B (dst) so trade routes read as movement.
  if (dash >= 0.5) {
    alpha *= step(0.5, fract(u * segLen / dash - flow));
  }

  float t = 1.0 - u;                              // 1 at A → 0 at B
  alpha *= exp(-2.0 * (1.0 - t));                 // endpoint fade, like line.glsl:35

  vec4 outCol = alpha * color.w * vec4(color.xyz, 1.0);

  if (isnan(outCol.r) || isnan(outCol.g) || isnan(outCol.b) || isnan(outCol.a)) {
    outCol = vec4(0.0);
  }

  fragColor = max(vec4(0.0), outCol);
}
