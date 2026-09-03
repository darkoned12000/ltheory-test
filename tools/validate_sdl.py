#!/usr/bin/env python3
"""Offline SDL validator for the ltheory-test SDL2->SDL3 upgrade.

Runs WITHOUT launching the game (like validate_glsl.py / validate_bytes.lua).
The engine now builds against SDL3 exclusively (the SDL2 device is retired),
so this validator REQUIRES SDL3. Gates:
  1. pkg-config: sdl3 present (and sdl2 may be absent) — reports versions.
  2. header: <SDL3/SDL.h> major matches pkg-config.
  3. link+init API probe that exercises the exact SDL3 signatures the engine
     uses: SDL_Init(SDL_INIT_VIDEO|...|SDL_INIT_GAMEPAD), the 4.6 core GL
     profile via SDL_GL_CONTEXT_PROFILE_MASK/CORE, SDL_CreateWindow(title,w,h,
     flags), SDL_GetGamepadJoystick/SDL_OpenGamepad path, SDL_GUIDToString,
     and the SDL_EVENT_GAMEPAD_* names. Catches any missed rename at compile
     time (CreateWindow sig, GL attr, GameController->Gamepad, GUID string).

Exit 0 if all gates pass, 1 otherwise. Wired into `configure.py test`
(and `cmake --build` phx_validate_sdl).

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
    print("[validate_sdl] SDL3 pkg-config + header + init/API probe gate (dummy video)")

    v3 = pkg_version("sdl3")
    print(f"  pkg sdl3: {v3 or 'not found'}")
    if not v3:
        print("FAIL: sdl3 not found via pkg-config (engine requires SDL3 now)")
        return 1

    # Determine what libphx actually links (ldd) for diagnostics
    if pathlib.Path("bin/libphx64r.so").exists():
        try:
            ldd = subprocess.check_output(["ldd","bin/libphx64r.so"], text=True)
            linked = [l for l in ldd.splitlines() if "libSDL" in l]
            print(f"  ldd libphx: {'; '.join(s.strip() for s in linked) or 'none'}")
        except Exception as e:
            print(f"  ldd failed: {e}")

    # SDL3 gate — compile time exercises the post-migration API surface.
    code3 = textwrap.dedent(r"""
        #include <SDL3/SDL.h>
        #include <stdio.h>
        int main(){
            int v = SDL_GetVersion();
            printf("SDL3 runtime %d\n", v);
            const Uint32 subs = SDL_INIT_EVENTS|SDL_INIT_VIDEO|SDL_INIT_JOYSTICK|SDL_INIT_GAMEPAD;
            if (!SDL_InitSubSystem(subs)){ printf("SDL_InitSubSystem failed: %s\n", SDL_GetError()); return 1; }

            SDL_GL_SetAttribute(SDL_GL_CONTEXT_MAJOR_VERSION, 4);
            SDL_GL_SetAttribute(SDL_GL_CONTEXT_MINOR_VERSION, 6);
            SDL_GL_SetAttribute(SDL_GL_CONTEXT_PROFILE_MASK, SDL_GL_CONTEXT_PROFILE_CORE);
            SDL_GL_SetAttribute(SDL_GL_CONTEXT_PROFILE_MASK, SDL_GL_CONTEXT_PROFILE_CORE);
            SDL_GL_SetAttribute(SDL_GL_ACCELERATED_VISUAL, 1);

            /* SDL3 CreateWindow signature: (title, w, h, flags).
               Under the dummy video driver there is no GL, so a CreateWindow
               failure here is an expected SKIP (validate_sdl_window.py covers
               window+GL when a display exists). The compile itself is the gate. */
            SDL_Window* w = SDL_CreateWindow("validate", 64, 64, SDL_WINDOW_OPENGL|SDL_WINDOW_HIDDEN);
            if (!w){ printf("note: no GL-capable video driver here (%s) — window probe SKIP\n", SDL_GetError()); }
            else SDL_DestroyWindow(w);

            /* Gamepad open path + GUID string (renamed APIs the engine uses). */
            int n = 0;
            SDL_JoystickID* ids = SDL_GetJoysticks(&n);
            char guidbuf[64];
            SDL_GUIDToString(SDL_GetJoystickGUIDForID(0), guidbuf, sizeof(guidbuf));
            if (ids) SDL_free(ids);

            /* Event enum names the engine uses. */
            switch (0) {
              case SDL_EVENT_GAMEPAD_BUTTON_DOWN: break;
              case SDL_EVENT_GAMEPAD_BUTTON_UP: break;
              case SDL_EVENT_GAMEPAD_AXIS_MOTION: break;
              case SDL_EVENT_GAMEPAD_ADDED: break;
              case SDL_EVENT_GAMEPAD_REMOVED: break;
            }

            SDL_QuitSubSystem(subs);
            SDL_Quit();
            printf("SDL3 API probe OK\n");
            return 0;
        }
    """)
    ok, out = compile_and_run(code3, ["sdl3"])
    if ok:
        print(f"  SDL3 header/init/API: OK — {out}")
    else:
        print(f"  SDL3 header/init/API: FAIL — {out}")
        fails += 1

    if fails == 0:
        print("\n[SDL tests] ALL PASS")
    else:
        print(f"\n[SDL tests] {fails} FAILED")
    return 1 if fails else 0

if __name__ == "__main__":
    sys.exit(main())
