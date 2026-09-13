#include brush
#include noise

void main() {
  BRUSH_BEGIN
  float safeR = max(1e-5, r);
  float safeHardness = max(1e-5, brushHardness);
  float a = brushAlpha * exp(-pow(safeR, safeHardness));

  vec3 powCol = pow(max(vec3(0.0), brushColor), vec3(4.0));
  float lenPow = length(powCol);
  vec3 normColor = (lenPow > 1e-6) ? (powCol / lenPow) : vec3(1.0);
  normColor = max(vec3(1e-5), normColor);

  vec3 outCol = canvasColor * exp(-a * canvasColor / normColor);

  if (isnan(outCol.r) || isnan(outCol.g) || isnan(outCol.b)) {
    outCol = canvasColor;
  }

  BRUSH_OUTPUT(max(vec3(0.0), outCol));
}
