#include math

layout(location = 0) out vec4 fragColor;
in vec2 uv;

uniform vec3 cubeLook;
uniform vec3 cubeUp;
uniform samplerCube src;
uniform sampler2D sampleBuffer;
uniform float angle;
uniform float srcLod;
uniform int samples;

vec3 cubeMapDir(vec2 uv) {
  uv = 2.0 * uv - vec2(1.0, 1.0);
  vec3 cubeRight = normalize(cross(cubeUp, cubeLook));
  return normalize(cubeLook + uv.x * cubeRight - uv.y * cubeUp);
}

float lum(vec3 rgb) {
  return dot(rgb, vec3(0.2126, 0.7152, 0.0722));
}

void main() {
  vec3 N = cubeMapDir(uv);
  vec3 T = normalize(cubeUp - N * dot(cubeUp, N));
  vec3 B = normalize(cross(N, T));
  vec4 c = vec4(0.0);
  float tw = 0.0;

  float invSamples = 1.0 / float(max(1, samples + 1));

  for (int i = 0; i < samples; ++i) {
    float u = float(i + 1) * invSamples;
    vec2 smp = textureLod(sampleBuffer, vec2(u, 0.5), 0.0).xy;
    float pitch = smp.x;
    float yaw = smp.y;
    vec3 L =
      cos(pitch) * N +
      sin(pitch) * sin(yaw) * T +
      sin(pitch) * cos(yaw) * B;

    /* Uniform weights: the estimator is the average of the environment over a
     * spherical cap of angular radius ~pitch, NOT a cosine-weighted irradiance
     * integral -- callers scale it (envAmbient / nebula.ambient). srcLod is the
     * mip whose texel footprint matches that cap (computed CPU-side from the
     * cube size), so each tap is already prefiltered to the scale it is
     * averaged at. That is what keeps the coarse levels smooth; sampling LOD 0
     * here made the wide caps a noisy 256-tap average of a point-lit env. */
    float w = 1.0;
    c += w * textureLod(src, L, srcLod);
    tw += w;
  }

  vec4 result = c / max(tw, 1e-5);
  result.w = 1.0;
  fragColor = result;
}
