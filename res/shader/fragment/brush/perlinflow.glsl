#include brush
#include noise

void main() {
  BRUSH_BEGIN
  float safeR = max(1e-5, r);
  float safeHardness = max(1e-5, brushHardness);
  float safeBrushSize = max(1e-4, brushSize);
  vec2 safeCanvasSize = max(vec2(1e-4), canvasSize);

  float a = brushAlpha * exp(-pow(safeR, safeHardness));
  vec2 v = vec2(
    fSmoothNoise(vec3(p / safeBrushSize + 1234.37 * brushSeed, brushTime), 8, 1.7),
    fSmoothNoise(vec3(p / safeBrushSize + 3333.0 * brushSeed, brushTime), 8, 1.7));

  vec2 dir = 2.0 * v - 1.0;
  float lenDir = length(dir);
  vec2 normV = (lenDir > 1e-6) ? (dir / lenDir) : vec2(0.0);

  vec3 smp = 1.01 * texture(canvas, uv + safeBrushSize * normV / safeCanvasSize).xyz;
  vec3 outCol = mix(canvasColor, smp * brushColor, a);

  if (isnan(outCol.r) || isnan(outCol.g) || isnan(outCol.b)) {
    outCol = canvasColor;
  }

  BRUSH_OUTPUT(max(vec3(0.0), outCol));
}
