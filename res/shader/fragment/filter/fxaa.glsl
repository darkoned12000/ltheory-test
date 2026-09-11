#include filter
#include color

layout(location = 0) out vec4 fragColor;

uniform vec2 viewportSize; // Screen resolution (width, height)

void main() {
  vec2 inverseVP = vec2(1.0) / viewportSize;

  vec3 rgbNW = texture(src, uv + vec2(-1.0, -1.0) * inverseVP).xyz;
  vec3 rgbNE = texture(src, uv + vec2( 1.0, -1.0) * inverseVP).xyz;
  vec3 rgbSW = texture(src, uv + vec2(-1.0,  1.0) * inverseVP).xyz;
  vec3 rgbSE = texture(src, uv + vec2( 1.0,  1.0) * inverseVP).xyz;
  vec3 rgbM  = texture(src, uv).xyz;

  vec3 luma = vec3(0.299, 0.587, 0.114);
  float lumaNW = dot(rgbNW, luma);
  float lumaNE = dot(rgbNE, luma);
  float lumaSW = dot(rgbSW, luma);
  float lumaSE = dot(rgbSE, luma);
  float lumaM  = dot(rgbM,  luma);

  float lumaMin = min(lumaM, min(min(lumaNW, lumaNE), min(lumaSW, lumaSE)));
  float lumaMax = max(lumaM, max(max(lumaNW, lumaNE), max(lumaSW, lumaSE)));

  vec2 dir;
  dir.x = -((lumaNW + lumaNE) - (lumaSW + lumaSE));
  dir.y =  ((lumaNW + lumaSW) - (lumaNE + lumaSE));

  float dirReduce = max((lumaNW + lumaNE + lumaSW + lumaSE) * (0.25 * 0.125), 1e-5);
  float rcpDirMin = 1.0 / (min(abs(dir.x), abs(dir.y)) + dirReduce);

  dir = min(vec2(8.0), max(vec2(-8.0), dir * rcpDirMin)) * inverseVP;

  vec3 rgbA = 0.5 * (
    texture(src, uv + dir * (1.0 / 3.0 - 0.5)).xyz +
    texture(src, uv + dir * (2.0 / 3.0 - 0.5)).xyz);
  vec3 rgbB = rgbA * 0.5 + 0.25 * (
    texture(src, uv + dir * -0.5).xyz +
    texture(src, uv + dir * 0.5).xyz);

  float lumaB = dot(rgbB, luma);
  if (lumaB < lumaMin || lumaB > lumaMax) {
    fragColor = vec4(rgbA, 1.0);
  } else {
    fragColor = vec4(rgbB, 1.0);
  }
}
