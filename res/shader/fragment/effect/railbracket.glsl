// The RAIL BRACKET: the pale ribbed C-channel beside each energy panel.
//
// FROM THE REFERENCE FRAMES
// =========================
// Each bracket is a "[" (left one a "]"): a tall POST made of pale ribs
// separated by near-black grooves, like piano keys, with two thin DARK arms
// reaching out toward the panel. The post carries an indicator LED at
// mid-height -- RED on the left post, BLUE on the right -- whose glow spills
// onto the neighbouring ribs.
//
// Mesh uv convention (see Rail.lua):
//   uv.y in [0,1]   the ribbed front/back face of a post; uv.y is the
//                   position along the post, uv.x across it
//   uv.y == -1      any other surface (arms, edges): plain dark metal
//   uv.x >= 5       the RIGHT post (its u is offset by 10), else the left
//
// Self-shaded, drawn in the forward pass (see AGENTS notes in Rail.lua).

#include fragment

layout(location = 0) out vec4 outColor;

uniform vec3  color;       // rib colour, a pale cool grey
uniform vec3  ledLeft;     // red
uniform vec3  ledRight;    // blue
uniform float time;

const float RIBS = 11.0;
const float POST_W = 0.19; // post width / post height, for round LED falloff

void main() {
  vec3 N = normalize(normal);
  vec3 V = normalize(eye - pos);            // toward the viewer
  // The mesh's winding is not trusted: always shade the side we can see.
  if (dot(N, V) < 0.0) N = -N;
  float ndv = clamp(dot(N, V), 0.0, 1.0);

  float side = step(5.0, uv.x);
  vec2  q = vec2(uv.x - 10.0 * side, uv.y);

  vec3 groove = vec3(0.025, 0.030, 0.055);
  vec3 col;

  if (q.y < -0.5) {
    // Arms and edges: near-black, with a pale rim where the surface turns
    // edge-on -- that is the thin bright outline on the arms.
    col = vec3(0.045, 0.050, 0.075) + color * 0.55 * pow(1.0 - ndv, 3.0);
  } else {
    // Ribs. r runs 0..1 inside each rib; the groove is the narrow gap.
    float r   = fract(q.y * RIBS);
    float rib = smoothstep(0.00, 0.20, r) * (1.0 - smoothstep(0.70, 0.90, r));
    // The post ends are capped: no rib in the outer 2%.
    rib *= smoothstep(0.0, 0.02, q.y) * (1.0 - smoothstep(0.98, 1.0, q.y));

    // Each rib is a little bevel: lighter at its top, darker at its bottom.
    float bevel = mix(1.05, 0.55, r);
    // The post bows outward: darker toward its two long edges.
    float bow = 1.0 - 0.40 * pow(abs(q.x - 0.5) * 2.0, 2.0);
    // A soft fixed key light and a headlight.
    float key = max(dot(N, normalize(vec3(0.30, 0.80, 0.50))), 0.0);
    float lit = 0.34 + 0.40 * ndv + 0.30 * key;

    vec3 ribCol = color * lit * bevel * bow;
    col = mix(groove, ribCol, rib);

    // ---- the LED -----------------------------------------------------
    vec3  led = mix(ledLeft, ledRight, side);
    // The LED sits on the post's INNER edge -- the edge that bounds the gap
    // -- which is where the reference frames show it: a red dot hanging in
    // the mouth of the lane.
    float lx = 1.0 - side;                  // 1 on the left post, 0 on the right
    float rr  = length(vec2((q.x - lx) * POST_W, q.y - 0.5));
    float pulse = 0.85 + 0.15 * sin(time * 3.0);
    float coreG = exp(-pow(rr / 0.020, 2.0));
    float haloG = exp(-pow(rr / 0.040, 2.0));
    // The halo is mostly seen on the ribs; the core is a hot dot.
    col += led * haloG * (0.25 + 1.1 * rib) * pulse;
    col += (led * 3.0 + vec3(0.25)) * coreG * pulse;
  }

  outColor = vec4(col, 1.0);
}
