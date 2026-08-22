varying vec2 uv;

uniform sampler2D src1;
uniform sampler2D src2;
uniform float mult1;
uniform float mult2;

void main() {
  gl_FragColor =
    mult1 * texture(src1, uv) +
    mult2 * texture(src2, uv);
}
