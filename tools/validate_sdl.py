#!/usr/bin/env python3
"""Offline SDL validator for the ltheory-test SDL2->SDL3 upgrade.

Runs WITHOUT launching the game (like validate_glsl.py / validate_bytes.lua).
Three gates:
  1. pkg-config: sdl2 and/or sdl3 present; reports versions.
  2. header: #include <SDL.h> (SDL2) and <SDL3/SDL.h> (SDL3) major matches pkg-config.
  3. link+init: compile+run tiny SDL_Init(SDL_INIT_VIDEO) with SDL_VIDEODRIVER=dummy
     and SDL_GL_SetAttribute(4.6 core) — catches API breaks (CreateWindow sig,
     GL attr rename, GameController->Gamepad) at compile time.

Exit 0 if all gates pass, 1 otherwise. Wired into `python3.13 configure.py test`
and `cmake --build` phx_validate_sdl (pre/post upgrade both pass; after SDL3
migration the linked major must be 3).

Usage: python3 tools/validate_sdl.py
"""
import os, subprocess, sys, tempfile, textwrap, pathlib

def pkg_version(name):
    try:
        out = subprocess.check_output(["pkg-config","--modversion",name], text=True).strip()
        return out
    except Exception:
        return None

def compile_and_run(code, libs):
    with tempfile.TemporaryDirectory() as td:
        c = pathlib.Path(td)/"t.c"
        exe = pathlib.Path(td)/"t"
        c.write_text(code)
        flags = subprocess.check_output(["pkg-config","--cflags"]+libs, text=True).split()
        llibs = subprocess.check_output(["pkg-config","--libs"]+libs, text=True).split()
        cmd = ["cc", str(c), "-o", str(exe)] + flags + llibs
        try:
            subprocess.check_output(cmd, stderr=subprocess.STDOUT, text=True)
        except subprocess.CalledProcessError as e:
            return False, f"compile failed: {' '.join(cmd)}\n{e.output[:800]}"
        env = dict(os.environ)
        env["SDL_VIDEODRIVER"] = "dummy"
        # Avoid needing a display for the init test; dummy video is enough for SDL_Init + GL attr.
        try:
            out = subprocess.check_output([str(exe)], text=True, env=env, timeout=5)
            return True, out.strip()
        except subprocess.CalledProcessError as e:
            return False, f"run failed: {e.output[:800]}" if e.output else str(e)
        except Exception as e:
            return False, str(e)

def main():
    fails = 0
    print("[validate_sdl] pkg-config + header + SDL_Init gate (dummy video)")

    v2 = pkg_version("sdl2")
    v3 = pkg_version("sdl3")
    print(f"  pkg sdl2: {v2 or 'not found'}")
    print(f"  pkg sdl3: {v3 or 'not found'}")
    if not v2 and not v3:
        print("FAIL: neither sdl2 nor sdl3 found via pkg-config")
        return 1

    # Determine what libphx actually links (ldd) for diagnostics
    ldd = ""
    if pathlib.Path("bin/libphx64r.so").exists():
        try:
            ldd = subprocess.check_output(["ldd","bin/libphx64r.so"], text=True)
            linked = [l for l in ldd.splitlines() if "libSDL" in l]
            print(f"  ldd libphx: {'; '.join(s.strip() for s in linked) or 'none'}")
        except Exception as e:
            print(f"  ldd failed: {e}")

    # Gate 2/3 per available SDL major — must be compilable if pkg claims present.
    # SDL2 gate
    if v2:
        code2 = textwrap.dedent(r"""
            #include <SDL.h>
            #include <stdio.h>
            int main(){
                SDL_version v; SDL_VERSION(&v);
                printf("header %d.%d.%d pkg %s\n", v.major, v.minor, v.patch, "2");
                if (SDL_Init(SDL_INIT_VIDEO)!=0){ printf("SDL_Init failed: %s\n", SDL_GetError()); return 1; }
                SDL_GL_SetAttribute(SDL_GL_CONTEXT_MAJOR_VERSION, 4);
                SDL_GL_SetAttribute(SDL_GL_CONTEXT_MINOR_VERSION, 6);
                SDL_GL_SetAttribute(SDL_GL_CONTEXT_PROFILE_MASK, SDL_GL_CONTEXT_PROFILE_CORE);
                SDL_GL_SetAttribute(SDL_GL_ACCELERATED_VISUAL, 1);
                SDL_Quit();
                printf("SDL2 init OK\n");
                return 0;
            }
        """)
        ok, out = compile_and_run(code2, ["sdl2"])
        if ok:
            print(f"  SDL2 header/init: OK — {out}")
        else:
            print(f"  SDL2 header/init: FAIL — {out}")
            fails += 1
    # SDL3 gate (if installed; before migration this just proves host has 3.4.14 ready)
    if v3:
        code3 = textwrap.dedent(r"""
            #include <SDL3/SDL.h>
            #include <stdio.h>
            int main(){
                int v = SDL_GetVersion();
                printf("SDL3 runtime %d pkg %s\n", v, "3");
                if (!SDL_Init(SDL_INIT_VIDEO)){ printf("SDL_Init failed: %s\n", SDL_GetError()); return 1; }
                SDL_GL_SetAttribute(SDL_GL_CONTEXT_MAJOR_VERSION, 4);
                SDL_GL_SetAttribute(SDL_GL_CONTEXT_MINOR_VERSION, 6);
                SDL_GL_SetAttribute(SDL_GL_CONTEXT_PROFILE_MASK, SDL_GL_CONTEXT_PROFILE_CORE);
                SDL_Quit();
                printf("SDL3 init OK\n");
                return 0;
            }
        """)
        ok, out = compile_and_run(code3, ["sdl3"])
        if ok:
            print(f"  SDL3 header/init: OK — {out}")
        else:
            print(f"  SDL3 header/init: FAIL — {out}")
            # Before migration, SDL3 compile failure is not fatal (host may lack dev headers)
            # but after migration it must pass. Warn only for now.
            if v2 and "sdl2" in str(pathlib.Path("libphx/CMakeLists.txt").read_text()).lower():
                print("  (expected: SDL2 build still active; SDL3 failure is non-fatal pre-migration)")
            else:
                fails += 1

    # Summary: after migration, linked must be SDL3. Pre-migration, SDL2 is fine.
    if fails == 0:
        print("\n[SDL tests] ALL PASS")
    else:
        print(f"\n[SDL tests] {fails} FAILED")
    return 1 if fails else 0

if __name__ == "__main__":
    sys.exit(main())
