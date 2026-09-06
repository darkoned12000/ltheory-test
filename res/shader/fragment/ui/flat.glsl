#include fragment


layout(location = 0) out vec4 fragColor;
uniform sampler2D tex;
uniform vec4 color;

/* Generic flat/textured immediate primitive: color modulated by the unit-0
 * texture. With the engine's 1x1 white dummy bound, this is a pure color
 * draw (the old fixed-function glColor + untextured quad behavior); with a
 * glyph/blit texture bound, it reproduces the old glColor * texenv result.
 * Used as Draw's default program for legacy color-state immediate draws
 * (Font_Draw, Tex2D_Draw/DrawEx, raw Draw.Rect/Tri/Line) under a GL core
 * profile, where no program bound means "rasterize nothing, silently". */
void main() {
  fragColor = color * texture(tex, uv);
}
