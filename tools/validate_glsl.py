#!/usr/bin/env python3
"""Offline GLSL validator for the ltheory-test shader tree.

Compiles + links every vertex/fragment shader in res/shader against a chosen
GLSL version WITHOUT launching the engine, replicating the engine's custom
preprocessor (#include resolution + #autovar stripping) and prepending the
#version the same way Shader.cpp does.

Why 'core' instead of 'compatibility': standalone EGL contexts (moderngl)
cannot create compatibility profiles on Mesa; GLX can. Since stage 3/4 the
tree contains zero compat-only builtins, so validating at core is both
possible and STRICTER than what runtime does.

How each file is validated: a fragment shader is linked with an auto-generated
stub vertex shader built from the fragment's own `in` declarations (and vice
versa), so every file gets true driver-side compile+link coverage without
knowing the real vs/fs pairs the engine uses at runtime.

Usage:
    python3 tools/validate_glsl.py [GLSL_VERSION]
        GLSL_VERSION: 130 140 150 330 400 ... (default 330)

Requires: pip install moderngl   (EGL backend, no window needed)
Exit code: 0 if all shaders pass, 1 otherwise.
"""
import pathlib
import re
import sys

import moderngl

def main() -> int:
    version = sys.argv[1] if len(sys.argv) > 1 else "330"
    version_line = f"#version {version} core\n"
    print(f"validating res/shader at {version.strip()} core")

    def resolve(path: pathlib.Path, stack: tuple) -> str:
        out = []
        for ln in path.read_text().split("\n"):
            m = re.match(r'^\s*#include\s+(\S+)\s*$', ln)
            if m:
                name = m.group(1)
                for cand in [path.parent / (name + ".glsl"),
                             pathlib.Path("res/shader/include") / (name + ".glsl")]:
                    if cand.exists():
                        assert str(cand) not in stack, f"circular include: {cand}"
                        out.append(resolve(cand, stack + (str(cand),)))
                        break
                else:
                    raise FileNotFoundError(f"{path}: unresolved include '{name}'")
            elif ln.strip().startswith("#autovar"):
                continue  # engine strips these before glShaderSource
            else:
                out.append(ln)
        return "\n".join(out)

    def interface(src: str, word: str):
        return re.findall(rf'^\s*{word}\s+(u?\w+)\s+(\w+)\s*;', src, re.M)

    ctx = moderngl.create_context(standalone=True, backend='egl')
    print(f"context: {ctx.info['GL_VERSION']}")

    ok = fails = 0
    for kind in ("vertex", "fragment"):
        for f in sorted(pathlib.Path("res/shader", kind).rglob("*.glsl")):
            try:
                src = version_line + resolve(f, ())
                if kind == "fragment":
                    ins = interface(src, "in")
                    stub = version_line + "".join(
                        f"out {t} v_{n};\n" for t, n in ins) + "void main(){}\n"
                    ctx.program(vertex_shader=stub, fragment_shader=src)
                else:
                    outs = interface(src, "out")
                    stub = version_line + "".join(
                        f"in {t} v_{n};\n" for t, n in outs) + "void main(){}\n"
                    ctx.program(vertex_shader=src, fragment_shader=stub)
                ok += 1
            except Exception as e:
                fails += 1
                print(f"\nFAIL {f}:\n{str(e)[:600]}")
    print(f"\n=== {ok} OK, {fails} FAIL ===")
    return 1 if fails else 0

if __name__ == "__main__":
    sys.exit(main())
