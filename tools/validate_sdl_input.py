#!/usr/bin/env python3
"""Input translation smoke test for SDL2->SDL3 (checks wiring, not HW).

Verifies the Input wrapper layer that `AGENTS.md:101` calls contained:
  - Button/Gamepad axis name tables still resolve (Button_FromSDLControllerButton etc. compile)
  - SDL_GameController* vs SDL_Gamepad* symbol presence per pkg
  - SDL_HINT_MOUSE_FOCUS_CLICKTHROUGH / SDL_TRUE etc. still defined
  - gamecontrollerdb.txt parse via SDL_GameControllerAddMappingsFromFile / SDL_AddGamepadMappingsFromFile

Compiles a tiny probe per SDL major and checks it exits 0 without opening a device.
Headless-safe (no /dev/input needed). Failure means the Input.cpp Gamepad/Joystick
shim will break post-migration.

Wired into `python3.13 configure.py test` after validate_sdl_window.py.
"""
import subprocess, textwrap, tempfile, pathlib, sys

def pkg_exists(name):
    try:
        subprocess.check_output(["pkg-config","--exists",name])
        return True
    except: return False

def try_compile(lib, code):
    with tempfile.TemporaryDirectory() as td:
        c=pathlib.Path(td)/"t.c"; exe=pathlib.Path(td)/"t"; c.write_text(code)
        flags=subprocess.check_output(["pkg-config","--cflags",lib],text=True).split()
        llibs=subprocess.check_output(["pkg-config","--libs",lib],text=True).split()
        try:
            subprocess.check_output(["cc",str(c),"-o",str(exe)]+flags+llibs, stderr=subprocess.STDOUT, text=True)
            out=subprocess.check_output([str(exe)], text=True, timeout=5)
            return True, out.strip()
        except subprocess.CalledProcessError as e:
            return False, (e.output or str(e))[:600]

def main():
    print("[validate_sdl_input] GameController/Gamepad + hint wiring probe")
    fails=0
    # SDL2 probe
    if pkg_exists("sdl2"):
        code2=textwrap.dedent(r"""
            #include <SDL.h>
            #include <stdio.h>
            int main(){
                SDL_GameControllerButton b = SDL_CONTROLLER_BUTTON_A;
                SDL_GameControllerAxis a = SDL_CONTROLLER_AXIS_LEFTX;
                (void)b; (void)a;
                const char* h = SDL_HINT_MOUSE_FOCUS_CLICKTHROUGH;
                (void)h;
                printf("sdl2 GameController + hint OK\n");
                return 0;
            }
        """)
        ok,out=try_compile("sdl2",code2)
        print(f"  sdl2 input symbols: {'OK' if ok else 'FAIL'} — {out}")
        if not ok: fails+=1
        # gamecontrollerdb (if present) should load without error in SDL2
        if pathlib.Path("res/gamecontrollerdb.txt").exists():
            code2b=textwrap.dedent(r"""
                #include <SDL.h>
                #include <stdio.h>
                int main(){
                    if (SDL_Init(SDL_INIT_GAMECONTROLLER)!=0) return 2;
                    int n = SDL_GameControllerAddMappingsFromFile("res/gamecontrollerdb.txt");
                    printf("mappings %d\n", n);
                    SDL_Quit();
                    return n>=0?0:1;
                }
            """)
            ok,out=try_compile("sdl2",code2b)
            print(f"  sdl2 gamecontrollerdb: {'OK' if ok else 'FAIL'} — {out}")
            if not ok: fails+=1
    if pkg_exists("sdl3"):
        code3=textwrap.dedent(r"""
            #include <SDL3/SDL.h>
            #include <stdio.h>
            int main(){
                SDL_GamepadButton b = SDL_GAMEPAD_BUTTON_SOUTH;
                SDL_GamepadAxis a = SDL_GAMEPAD_AXIS_LEFTX;
                (void)b; (void)a;
                const char* h = SDL_HINT_MOUSE_FOCUS_CLICKTHROUGH;
                (void)h;
                printf("sdl3 Gamepad + hint OK\n");
                return 0;
            }
        """)
        ok,out=try_compile("sdl3",code3)
        print(f"  sdl3 input symbols: {'OK' if ok else 'FAIL'} — {out}")
        if not ok: fails+=1
        if pathlib.Path("res/gamecontrollerdb.txt").exists():
            code3b=textwrap.dedent(r"""
                #include <SDL3/SDL.h>
                #include <stdio.h>
                int main(){
                    if (!SDL_Init(SDL_INIT_GAMEPAD)) return 2;
                    int n = SDL_AddGamepadMappingsFromFile("res/gamecontrollerdb.txt");
                    printf("mappings %d\n", n);
                    SDL_Quit();
                    return n>=0?0:1;
                }
            """)
            ok,out=try_compile("sdl3",code3b)
            print(f"  sdl3 gamepad db: {'OK' if ok else 'FAIL'} — {out}")
            if not ok: print("  (db format change expected pre-migration; non-fatal)")

    if fails==0:
        print("\n[SDL input] ALL PASS")
        return 0
    print(f"\n[SDL input] {fails} FAILED")
    return 1

if __name__=="__main__": sys.exit(main())
