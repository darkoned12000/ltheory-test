#include vertex

void main() {
  uv = vertex_uv;
  pos = vertex_position;
  gl_Position = gl_ProjectionMatrix * (gl_ModelViewMatrix * vec4(vertex_position, 1.0));
}
