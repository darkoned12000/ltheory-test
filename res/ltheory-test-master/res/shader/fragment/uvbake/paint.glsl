#include fragment
#include math


layout(location = 0) out vec4 fragColor;
uniform float brushSize;
uniform vec3 brushColor;
uniform vec3 brushPos;

void main() {
  float r = length(brushPos - vertPos.xyz);
  float alpha = exp(-pow2(r / brushSize));
  fragColor = vec4(brushColor, alpha);
}
