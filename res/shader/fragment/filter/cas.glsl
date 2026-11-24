/* Contrast Adaptive Sharpening (AMD CAS) - simplified single-pass. */
#include filter

layout(location = 0) out vec4 fragColor;

uniform float strength;

void main() {
  vec2 ts = 1.0 / size;
vec3 a = texture(src, uv + vec2(-ts.x, -ts.y)).rgb;
  vec3 b = texture(src, uv + vec2( 0.0,      -ts.y)).rgb;
  vec3 c = texture(src, uv + vec2( ts.x, -ts.y)).rgb;
  vec3 d = texture(src, uv + vec2(-ts.x,  0.0)).rgb;
  vec3 e = texture(src, uv).rgb;
  vec3 f = texture(src, uv + vec2( ts.x,  0.0)).rgb;
  vec3 g = texture(src, uv + vec2(-ts.x,  ts.y)).rgb;
  vec3 h = texture(src, uv + vec2( 0.0,       ts.y)).rgb;
  vec3 i = texture(src, uv + vec2( ts.x,  ts.y)).rgb;

  vec3 mn = min(min(min(a,b),min(c,d)), min(min(e,f),min(g,min(h,i))));
  vec3 mx = max(max(max(a,b),max(c,d)), max(max(e,f),max(g,max(h,i))));

  vec3 amp = clamp((mx - mn) / max(mx, vec3(1e-4)), 0.0, 1.0);
  amp = amp * strength;

  vec3 avg = (a+b+c+d+e+f+g+h+i) / 9.0;
  vec3 outc = e + (e - avg) * amp;
  fragColor = vec4(clamp(outc, 0.0, 1.0), 1.0);
}
