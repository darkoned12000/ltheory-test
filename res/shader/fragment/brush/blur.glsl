#include brush
#include noise

#define SAMPLES 16

void main() {
  BRUSH_BEGIN
  float safeR = max(1e-5, r);
  float safeHardness = max(1e-5, brushHardness);
  float a = brushAlpha * exp(-pow(safeR, safeHardness));
  vec3 c = vec3(0.0);
  float tw = 0.0;
  float uvn = noise(noise(uv) + brushSeed);
  vec2 safeCanvasSize = max(vec2(1e-4), canvasSize);

  for (int i = 0; i < SAMPLES; ++i) {
    float t = radians(360.0) * (float(i) + noise(uvn + float(i))) / float(SAMPLES);
    float nVal = clamp(noise(uvn + 1337.0 * brushSeed + float(i)), 0.0, 0.999);
    float sampleR = -brushSize * log(max(1e-6, 1.0 - nVal));
    vec2 dir = sampleR * vec2(cos(t), sin(t));
    float w = 1.0;
    c += w * texture(canvas, uv + dir / safeCanvasSize).xyz;
    tw += w;
  }

  vec3 avgC = c / max(1e-5, tw);
  vec3 outCol = mix(canvasColor, avgC, a);

  if (isnan(outCol.r) || isnan(outCol.g) || isnan(outCol.b)) {
    outCol = canvasColor;
  }

  BRUSH_OUTPUT(max(vec3(0.0), outCol));
}
