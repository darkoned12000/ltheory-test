#include math
#include noise

layout(location = 0) out vec4 fragColor;
in vec2 uv;

uniform float radius;
uniform sampler2D points;
uniform sampler3D sdf;

const int kSamples = 128;
const float kThresh = 0.3;

void main() {
  vec3 p = 0.5 * texture(points, uv).xyz + 0.5;
  float total = 0.0;
  float offset = 133.7 * noise(uv);

  for (int i = 0; i < kSamples; ++i) {
    float fi = float(i);
    float a = TAU * noise(fi + 3.0 + offset * 1.3);
    float z = 2.0 * noise(fi + offset) - 1.0;

    float ring = sqrt(max(0.0, 1.0 - z * z));
    float x = sin(a) * ring;
    float y = cos(a) * ring;
    float r = radius * sqrt(max(0.0, noise(fi + 51.0 + offset * 1.5)));

    float s = texture(sdf, p + r * vec3(x, y, z)).x;
    if (s < 0.0)
      total += 1.0;
  }

  total /= float(kSamples);
  total = max(0.0, (total - kThresh) / (1.0 - kThresh));
  total = 1.0 - total;
  total *= total;

  fragColor = vec4(total, 0.0, 0.0, 1.0);
}
