// Conventional, unjittered clip transform for depth-only shadow maps.
#include vertex

#autovar mat4 mView
#autovar mat4 mProj

void main () {
  gl_Position = mProj * (mView * (mWorld * vec4(vertex_position, 1.0)));
}
