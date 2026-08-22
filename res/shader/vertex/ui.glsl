#include vertex

#autovar mat4 mViewUI
#autovar mat4 mProjUI

void main() {
  uv = vertex_uv;
  pos = vertex_position;
  gl_Position = mProjUI * (mViewUI * vec4(vertex_position, 1.0));
}
