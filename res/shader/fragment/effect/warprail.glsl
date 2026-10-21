// The WARP RAIL energy panel.
//
// WHAT THE REFERENCE FRAMES SHOW
// ==============================
// Each panel is NOT a stripe, a tube or a noise field. It is a flat
// rectangle of dotted blue lattice whose brightness is organised as
// CONCENTRIC SIMILAR RECTANGLES: bright in the middle, dimmer rings stepping
// outward, with the outer cells reduced to faint dots. The lattice is made
// of thin lines that cross in brighter NODES; the rings pick out the nodes,
// which is why they read as dotted rectangles rather than solid outlines.
// The rings travel (the pulse), the node brightness twinkles a little.
//
// The mesh gives uv in [0,1] across the panel, with u = 1 on the edge
// NEXT TO THE BRACKET (the inner edge) on both panels. The glow fades out
// there so the bracket's C-channel has a dark pocket around it.
//
// Uniforms (all set by Rail.lua):
//   scale      frame size in world units (used for the distance fade)
//   time       seconds, for the twinkle
//   flowSpeed  ship speed along the lane, for the twinkle rate
//   gridScale  lattice cells across the panel, (columns, rows)
//   phase      ring phase in CYCLES, accumulated on the CPU so a changing
//              flow speed never makes the rings jump

#include fragment

layout(location = 0) out vec4 outColor;

uniform vec3  scale;
uniform float time;
uniform float flowSpeed;
uniform vec2  gridScale;
uniform float phase;

const float TAU          = 6.2831853;
const float RING_SPACING = 0.17;    // ring pitch, as a fraction of the half-panel
const float LINE_HALF    = 0.045;   // lattice line half-width, in cells
const float NODE_R       = 0.24;    // radius of the glowing node dots, in cells

float hash21(vec2 p) {
  return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453);
}

void main() {
  // p runs -1..1 across the panel; d is the CHEBYSHEV distance from the
  // centre, so the iso-lines are rectangles with the panel's own aspect.
  vec2  p = (uv - 0.5) * 2.0;
  float d = max(abs(p.x), abs(p.y));

  // ---- the lattice ------------------------------------------------------
  vec2 g  = uv * gridScale;
  vec2 fw = max(fwidth(g), vec2(1e-4));
  vec2 e  = 0.5 - abs(fract(g) - 0.5);          // 0 ON a grid line
  // (not called "line": reserved word in GLSL 4.x)
  float lx = 1.0 - smoothstep(LINE_HALF - fw.x, LINE_HALF + fw.x, e.x);
  float ly = 1.0 - smoothstep(LINE_HALF - fw.y, LINE_HALF + fw.y, e.y);
  float lines = max(lx, ly);
  // Nodes are soft round dots in the MIDDLE of each cell -- the "dotted"
  // look. (e is 0.5 at a cell's centre, so cd is 0 there.)
  vec2  cd    = 0.5 - e;                          // offset from the cell centre
  float nodes = 1.0 - smoothstep(NODE_R - fw.x, NODE_R + fw.x, length(cd));
  // When the cells shrink toward a pixel, settle on the average rather than
  // shimmer.
  float calm = smoothstep(0.25, 0.60, max(fw.x, fw.y));
  lines = mix(lines, 0.30, calm);
  nodes = mix(nodes, 0.05, calm);
  float structure = 0.10 + 0.30 * lines + 1.10 * nodes;

  // Per-cell twinkle.
  float h  = hash21(floor(g));
  float tw = 0.82 + 0.18 * sin(time * (2.0 + flowSpeed * 0.0015) + h * TAU);

  // ---- the concentric rings ---------------------------------------------
  // d / RING_SPACING + phase: as phase grows the crests move INWARD. Negate
  // the phase on the CPU side to run them outward.
  float ring = pow(0.5 + 0.5 * cos(TAU * (d / RING_SPACING + phase)), 3.0);

  // Brightness falls off from the centre but never to zero: the outer
  // cells stay visible as faint dots.
  float env  = 0.10 + 0.90 * exp(-2.8 * d);
  // A filled, brighter core rectangle at the very centre -- the reference
  // frames have a saturated blue block in the middle of each panel.
  float core = 1.0 - smoothstep(0.08, 0.40, d);

  float I = ((0.18 + 1.55 * ring) * env * structure + core * (0.35 + 0.5 * lines)) * tw;

  vec3 blue = vec3(0.22, 0.62, 2.40);
  vec3 hot  = vec3(0.55, 0.90, 1.00);
  vec3 c = blue * I + hot * pow(ring, 3.0) * env * nodes * 1.1;

  // ---- edges --------------------------------------------------------------
  // (These are written as 1.0 - smoothstep(lo, hi, x) rather than
  // smoothstep(hi, lo, x): a descending edge pair is UNDEFINED in GLSL,
  // even though every driver in practice evaluates it the way you want.)
  float fade = (1.0 - smoothstep(0.84, 1.00, uv.x))   // dark pocket by the bracket
             * smoothstep(0.00, 0.03, uv.x)
             * smoothstep(0.00, 0.05, uv.y)
             * (1.0 - smoothstep(0.95, 1.00, uv.y));

  // The old fog term is gone (the engine's haze was removed), so fade with
  // distance explicitly. Range scales with the frame size.
  float k = scale.x / 1400.0;
  fade *= 1.0 - smoothstep(20000.0 * k, 70000.0 * k, length(pos - eye));

  // Additive field: colour already carries the fade, alpha carries it too.
  outColor = vec4(c, 1.0) * fade;
}
