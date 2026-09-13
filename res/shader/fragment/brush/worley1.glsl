#include brush
#include noise

void main() {
  BRUSH_BEGIN
  float safeBrushSize = max(1e-4, brushSize);
  float a = brushAlpha * exp(-max(0.0, r));

  float cellNoiseVal = max(0.0, 2.0 * fCellNoise(p / safeBrushSize, 1000.0 * brushSeed, 24, 1.5));
  a *= exp(-pow(max(1e-5, cellNoiseVal), 1.5));

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
