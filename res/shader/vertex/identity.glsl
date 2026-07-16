#include vertex

void main() {
  uv = vertex_uv;
  pos = vertex_position;
  gl_Position = vec4(vertex_position, 1.0);
}
