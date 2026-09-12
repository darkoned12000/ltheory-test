#include fragment

layout(location = 0) out vec4 fragColor;
uniform vec3 color;

void main() {
  vec3 safeColor = color;
  if (isnan(safeColor.r) || isnan(safeColor.g) || isnan(safeColor.b)) {
    safeColor = vec3(0.0);
  }
  fragColor = vec4(clamp(safeColor, vec3(0.0), vec3(10.0)), 1.0);
  FRAGMENT_CORRECT_DEPTH;
}
