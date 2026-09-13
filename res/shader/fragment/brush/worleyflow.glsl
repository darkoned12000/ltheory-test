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
    fCellNoise(vec2(p / safeBrushSize + 1337.3713), 1000.0 * brushSeed, 16, 2.0),
    fCellNoise(vec2(p / safeBrushSize), 2000.0 * brushSeed, 16, 2.0));

  vec2 dir = 2.0 * v - 1.0;
  float lenDir = length(dir);
  vec2 normV = (lenDir > 1e-6) ? (dir / lenDir) : vec2(0.0);

  vec3 smp = 1.1 * texture(canvas, uv + safeBrushSize * normV / safeCanvasSize).xyz;
  vec3 outCol = mix(canvasColor, smp * (0.5 + 0.5 * brushColor), a);

  if (isnan(outCol.r) || isnan(outCol.g) || isnan(outCol.b)) {
    outCol = canvasColor;
  }

  BRUSH_OUTPUT(max(vec3(0.0), outCol));
}
