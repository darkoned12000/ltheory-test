#include fragment

layout(location = 0) out vec4 fragColor;
uniform vec4 color;

void main() {
  vec4 safeColor = color;
  if (isnan(safeColor.r) || isnan(safeColor.g) || isnan(safeColor.b) || isnan(safeColor.a)) {
    safeColor = vec4(0.0, 0.0, 0.0, 1.0);
  }
  fragColor = clamp(safeColor, vec4(0.0), vec4(10.0));
  FRAGMENT_CORRECT_DEPTH;
}
