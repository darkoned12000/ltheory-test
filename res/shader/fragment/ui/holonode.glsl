/* Procedural holographic node and active-path beam. */
#include fragment

layout(location = 0) out vec4 fragColor;

uniform int   mode;        // 0 node, 1 beam
uniform float time;
uniform float state;       // 0 normal, 1 active
uniform float drillable;
uniform float radius;
uniform vec4  colPrimary;
uniform vec4  colAccent;
uniform vec2  quadSize;
uniform vec2  segA;
uniform vec2  segB;
uniform float thickness;

float coverage(float d, float width) {
  float lo = max(0.0, width - 0.6);
  float hi = max(lo + 0.001, width + 0.6);
  return 1.0 - smoothstep(lo, hi, d);
}

void main() {
  if (mode == 0) {
    vec2 p = (uv - 0.5) * quadSize;
    float r = length(p);
    float maxR = min(quadSize.x, quadSize.y) * 0.5;
    float ringR = max(1.0, radius);

    vec3 baseCol = mix(colPrimary.rgb, colAccent.rgb, clamp(state, 0.0, 1.0));
    float alpha = colPrimary.a;

    float ring = coverage(abs(r - ringR), thickness);
    float dRing = abs(r - ringR);
    float glow = exp(-dRing * 0.22) * 0.55 + exp(-r * 0.14) * 0.35;

    float coreR = max(2.2, ringR * 0.22);
    float core = coverage(r, coreR);

    float inner = 0.0;
    if (drillable > 0.5 && ringR > 7.0) {
      inner = coverage(abs(r - ringR * 0.68), 1.2) * 0.65;
    }

    float outerHalo = 0.0;
    if (state > 0.5) {
      float outerR = ringR * 1.32 + sin(time * 5.0) * 1.5;
      float angle = atan(p.y, p.x) + time * 1.4;
      float dashes = smoothstep(-0.2, 0.2, sin(angle * 12.0));
      outerHalo = coverage(abs(r - outerR), 1.4) * dashes * 0.95;
    }

    float intensity = ring * 1.35 + glow + core * 1.5 + inner + outerHalo * 1.2;
    float clip = 1.0 - smoothstep(maxR - 4.0, maxR, r);
    float a = alpha * clip;

    // Additive blending is GL_ONE/GL_ONE, so RGB carries its own coverage.
    vec3 rgb = (baseCol * intensity + vec3(core * 0.45)) * a;
    float outAlpha = clamp(intensity * a, 0.0, 1.0);
    fragColor = vec4(rgb, outAlpha);
  } else {
    vec2 p = uv * quadSize;
    vec2 pa = p - segA;
    vec2 ba = segB - segA;
    float len2 = max(dot(ba, ba), 1e-4);
    float t = clamp(dot(pa, ba) / len2, 0.0, 1.0);
    float d = length(pa - ba * t);

    vec3 beamCol = mix(colPrimary.rgb, colAccent.rgb, t * clamp(state, 0.0, 1.0));
    float core = coverage(d, thickness);
    float halo = exp(-d * 0.28) * (0.45 + 0.35 * state);
    float pulse = state > 0.5
      ? 0.85 + 0.25 * sin(t * 18.0 - time * 8.0)
      : 1.0;

    float intensity = (core * 1.3 + halo) * pulse;
    float a = colPrimary.a;
    vec3 rgb = beamCol * intensity * a;
    float outAlpha = clamp(intensity * a, 0.0, 1.0);
    fragColor = vec4(rgb, outAlpha);
  }

  if (isnan(fragColor.r) || isnan(fragColor.g)
      || isnan(fragColor.b) || isnan(fragColor.a)) {
    fragColor = vec4(0.0);
  }
}
