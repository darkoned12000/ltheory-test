// Standardizes header layout using #include filter and guards incoming
// RGB color channels against negative values before computing average color.

#include filter
#include math
#include color

layout(location = 0) out vec4 fragColor;

void main() {
  vec3 c = max(texture(src, uv).xyz, vec3(0.0));
  float a = 1.0 + avg(c);
  fragColor = vec4(c, a);
}
