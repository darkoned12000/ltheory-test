#include brush

void main() {
  BRUSH_BEGIN
  float safeR = max(1e-5, r);
  float safeHardness = max(1e-5, brushHardness);
  float a = brushAlpha * exp(-pow(safeR, safeHardness));
  vec3 outCol = canvasColor * (vec3(1.0) + a * brushColor);

  if (isnan(outCol.r) || isnan(outCol.g) || isnan(outCol.b)) {
    outCol = canvasColor;
  }

  BRUSH_OUTPUT(max(vec3(0.0), outCol));
}
