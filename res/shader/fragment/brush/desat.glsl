#include brush
#include color
#include math
#include noise

void main() {
  BRUSH_BEGIN
  float safeR = max(1e-5, r);
  float safeHardness = max(1e-5, brushHardness);
  float a = brushAlpha * exp(-pow(safeR, safeHardness));
  float l = lum(canvasColor);
  vec3 dc = mix(canvasColor, vec3(l), saturate(a * brushColor));
  float dcLum = lum(dc);
  dc *= (dcLum > 1e-6) ? (l / dcLum) : 1.0;

  if (isnan(dc.r) || isnan(dc.g) || isnan(dc.b)) {
    dc = canvasColor;
  }

  BRUSH_OUTPUT(max(vec3(0.0), dc));
}
