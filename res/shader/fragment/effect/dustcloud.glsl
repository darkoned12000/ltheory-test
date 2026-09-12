#include fragment
#include gamma
#include math
#include noise
#include color

#autovar samplerCube irMap
#autovar vec3 starDir
#autovar vec3 sunColor

layout(location = 0) out vec4 fragColor;

uniform sampler2D texDust;
uniform sampler2D texDepth;
uniform vec3 sunColor;

// Henyey-Greenstein phase function for forward star scattering
float hgPhase(float cosTheta, float g) {
  float g2 = g * g;
  float denom = pow(max(1e-5, 1.0 + g2 - 2.0 * g * cosTheta), 1.5);
  return (1.0 - g2) / (4.0 * 3.14159265 * denom);
}

void main() {
  vec3 V = pos - eye;
  float particleDist = length(V);
  float dist = particleDist / 1024.0;

  // 1. Ambient lighting sampled from skybox IR map
  vec4 bg = textureLod(irMap, V, 2.0);
  vec3 c = mix(vec3(0.2), mix(bg.xyz, 0.75 * sqrt(bg.xyz), 0.25), 0.8);

  // 2. Henyey-Greenstein silver-lining glow when looking toward starDir
  vec3 safeV = normalize(V + vec3(1e-6));
  float cosTheta = dot(safeV, normalize(starDir));
  float scatter = hgPhase(cosTheta, 0.6);
  c += sunColor * (0.08 * scatter);

  // 3. 3D world-space procedural cellular noise (replaces flat 2D billboard textures)
  float a = fCellNoise(pos * 0.005 + vec3(33.0), 1337.0, 4, 2.0);

  // Distance falloff bounds
  a *= saturate((1.0 - dist) / 0.25);
  a *= saturate(dist / 0.25);
  a *= 0.75;
  a = saturate(a);
  a *= a;

  // 4. Soft Particle Intersections (Depth Feathering)
  float sceneDepth = textureLod(texDepth, uv, 0.0).r;
  if (sceneDepth < 950000.0) {
    float softness = 32.0; // Distance in meters over which alpha smooths out
    float depthFade = saturate((sceneDepth - particleDist) / softness);
    a *= depthFade;
  }

  fragColor = vec4(linear(c), a);
  FRAGMENT_CORRECT_DEPTH;
}
