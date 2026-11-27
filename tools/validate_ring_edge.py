#!/usr/bin/env python3
"""Headless pixel contract for the shared UI ring shader.

The ring is rendered on its padded square quad. Its glow must reach exactly
zero at the quad edge; otherwise the bounding square becomes visible beneath
otherwise circular nodes.
"""

from pathlib import Path
import re
import sys

import moderngl


ROOT = Path(__file__).resolve().parent.parent


def resolve(path: Path, stack=()) -> str:
    out = []
    for line in path.read_text().splitlines():
        match = re.match(r'^\s*#include\s+(\S+)\s*$', line)
        if match:
            name = match.group(1)
            for candidate in (path.parent / (name + '.glsl'),
                              ROOT / 'res/shader/include' / (name + '.glsl')):
                if candidate.exists():
                    if str(candidate) in stack:
                        raise RuntimeError(f'circular include: {candidate}')
                    out.append(resolve(candidate, stack + (str(candidate),)))
                    break
            else:
                raise FileNotFoundError(f'{path}: unresolved include {name}')
        elif line.strip().startswith('#autovar'):
            continue
        else:
            out.append(line)
    return '\n'.join(out)


def main() -> int:
    ctx = moderngl.create_context(standalone=True, backend='egl')
    version = '#version 460 core\n'
    fragment = version + resolve(ROOT / 'res/shader/fragment/ui/ring.glsl')
    vertex = version + r'''
out vec2 uv;
out vec3 pos;
out vec3 normal;
out vec3 vertNormal;
out vec3 vertPos;
out float flogz;
flat out vec4 color;
flat out vec4 widget_a;

void main() {
  vec2 p = vec2(float((gl_VertexID << 1) & 2), float(gl_VertexID & 2));
  uv = p;
  pos = vec3(0.0);
  normal = vec3(0.0);
  vertNormal = vec3(0.0);
  vertPos = vec3(0.0);
  flogz = 0.0;
  color = vec4(0.2, 0.7, 1.0, 1.0);
  widget_a = vec4(12.0, 36.0, 36.0, 0.0);
  gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0);
}
'''
    program = ctx.program(vertex_shader=vertex, fragment_shader=fragment)
    vao = ctx.vertex_array(program, [])
    size = 64
    texture = ctx.texture((size, size), 4, dtype='f1')
    framebuffer = ctx.framebuffer(color_attachments=[texture])
    framebuffer.use()
    ctx.viewport = (0, 0, size, size)
    ctx.clear(0.0, 0.0, 0.0, 1.0)
    vao.render(mode=moderngl.TRIANGLES, vertices=3)
    pixels = framebuffer.read(components=4, alignment=1)

    def alpha(x: int, y: int) -> float:
        offset = (y * size + x) * 4
        return pixels[offset + 3] / 255.0

    edge_samples = [
        alpha(32, 0), alpha(32, size - 1),
        alpha(0, 32), alpha(size - 1, 32),
        alpha(0, 0), alpha(size - 1, 0),
        alpha(0, size - 1), alpha(size - 1, size - 1),
    ]
    edge_max = max(edge_samples)
    ring_alpha = alpha(53, 32)  # radius 12 on a 36-unit quad in a 64 px target.

    if edge_max > 1.0 / 255.0:
        print(f'FAIL - ring glow leaks at the square quad edge (max alpha {edge_max:.3f})')
        return 1
    if ring_alpha < 0.25:
        print(f'FAIL - ring edge fade removed the visible ring (alpha {ring_alpha:.3f})')
        return 1
    print('ok   - ring shader is transparent at every square quad edge')
    print(f'ok   - ring band remains visible (alpha {ring_alpha:.3f})')
    return 0


if __name__ == '__main__':
    sys.exit(main())
