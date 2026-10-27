/* Wrapped quad for dust cloud / god rays. */
#include vertex
#include math

#autovar vec3 eye
#autovar mat4 mView
#autovar mat4 mProj

uniform vec3 axis;
uniform vec2 size;

out float opacity;
out vec3 attrib;

const float kWrapDistance = 1024.0;

void main() {
  VS_BEGIN

  vec4 wp = mWorld * vec4(vertPos, 1.0);
  vec3 toCam = eye - wp.xyz;
  toCam = 2.0 * (fract(toCam / kWrapDistance) * kWrapDistance) - vec3(kWrapDistance);
  wp.xyz = eye - toCam;
  vec3 up = normalize(axis);
  vec3 toCamDir = normalize(toCam + vec3(1e-6));
  vec3 crossVec = cross(toCamDir, up);
  vec3 right = (length(crossVec) > 1e-6) ? normalize(crossVec) : vec3(1.0, 0.0, 0.0);
  wp.xyz += size.x * uv.x * right;
  wp.xyz += size.y * uv.y * up;

  pos = wp.xyz;
  opacity = 1.0;
  attrib = vertex_normal;
  gl_Position = mProj * (mView * wp);
  VS_END
}
