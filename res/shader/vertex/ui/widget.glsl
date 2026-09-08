#autovar mat4 mViewUI
#autovar mat4 mProjUI

uniform mat4 mViewUI;
uniform mat4 mProjUI;

layout(location = 0) in vec3 vertex_position;
layout(location = 2) in vec2 vertex_uv;
layout(location = 3) in vec4 vertex_color;
layout(location = 4) in vec4 vertex_widget_a;
layout(location = 5) in vec4 vertex_widget_b;

out vec2 uv;
out vec3 pos;
flat out vec4 color;
flat out vec4 widget_a;
flat out vec4 widget_b;

void main() {
  uv = vertex_uv;
  pos = vertex_position;
  color = vertex_color;
  widget_a = vertex_widget_a;
  widget_b = vertex_widget_b;
  gl_Position = mProjUI * (mViewUI * vec4(vertex_position, 1.0));
}