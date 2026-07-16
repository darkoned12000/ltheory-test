#include fragment

// UI triangle SDF used by UI.DrawEx.Tri / Arrow (e.g. the HUD lock indicator).
// Draws a soft-filled outlined triangle between the three screen-space points
// p1, p2, p3. NOTE: p1/p2/p3 are uniforms and therefore READ-ONLY -- the SDF
// math copies them into local q1/q2/q3 before displacing. `pos` is the
// interpolated vertex position (vec3); use pos.xy for the 2D SDF.
uniform vec2 p1;
uniform vec2 p2;
uniform vec2 p3;
uniform vec4 color;

const float kRadius = 0.5;

void main() {
  vec2 p = pos.xy;
  vec2 center = (p1 + p2 + p3) / 3.0;
  vec2 q1 = p1 + kRadius * normalize(center - p1);
  vec2 q2 = p2 + kRadius * normalize(center - p2);
  vec2 q3 = p3 + kRadius * normalize(center - p3);

  vec2 d1 = normalize(q2 - q1);
  vec2 d2 = normalize(q3 - q2);
  vec2 d3 = normalize(q1 - q3);
  float ed1 = length(p - (q1 + d1 * clamp(dot(d1, p - q1), 0.0, length(q2 - q1))));
  float ed2 = length(p - (q2 + d2 * clamp(dot(d2, p - q2), 0.0, length(q3 - q2))));
  float ed3 = length(p - (q3 + d3 * clamp(dot(d3, p - q3), 0.0, length(q1 - q3))));
  float edm = min(ed1, min(ed2, ed3));

  vec2 n1 = vec2(-d1.y, d1.x);
  vec2 n2 = vec2(-d2.y, d2.x);
  vec2 n3 = vec2(-d3.y, d3.x);
  n1 *= sign(dot(n1, q3 - q1));
  n2 *= sign(dot(n2, q1 - q2));
  n3 *= sign(dot(n3, q2 - q3));
  float dist1 = -dot(n1, p - q1);
  float dist2 = -dot(n2, p - q2);
  float dist3 = -dot(n3, p - q3);
  float dist = max(dist1, max(dist2, dist3));
  float idm = step(0.0, dist) * edm;

  float fill    = exp(-1.0 * idm);
  float glow    = exp(-pow(0.25 * edm, 0.75));

  float alpha = 0.0;
  alpha += 0.8 * fill;
  alpha += 0.3 * glow;

  gl_FragColor = alpha * color.w * vec4(2.0 * color.xyz, 1.0);
}
