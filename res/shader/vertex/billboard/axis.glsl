/* Axis-aligned billboard. */
#include vertex
#include math

#autovar vec3 eye
#autovar mat4 mView
#autovar mat4 mProj

uniform vec2 size;

void main() {
  VS_BEGIN
  vec4 wp = mWorld * vec4(vertPos, 1.0);
  vec3 toCam = normalize(eye - wp.xyz);
  vec3 look = normalize((mWorld * vec4(0, 0, 1, 0)).xyz);
  vec3 crossVec = cross(toCam, look);
  vec3 right = (length(crossVec) > 1e-6) ? normalize(crossVec) : vec3(1.0, 0.0, 0.0);
  wp.xyz += size.x * uv.x * right;
  wp.xyz += size.y * uv.y * look;
  pos = wp.xyz;
  gl_Position = mProj * (mView * wp);
  VS_END
}
