#include fragment

uniform sampler2D canvas;
uniform vec2 canvasSize;

uniform float brushAlpha;
uniform float brushHardness;
uniform float brushSize;
uniform float brushSeed;
uniform float brushTime;
uniform vec3 brushColor;
uniform vec2 brushOrigin;

#define BRUSH_BEGIN                                                            \
  vec3 canvasColor = texture(canvas, uv).xyz;                                \
  vec2 p = canvasSize * uv;                                                    \
  float r = length(brushOrigin - p) / brushSize;                               \

layout(location = 0) out vec4 fragColor;
#define BRUSH_OUTPUT(x) fragColor = vec4((x).xyz, 1.0);
