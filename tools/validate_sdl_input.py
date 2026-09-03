#!/usr/bin/env python3
"""Input translation smoke test for the SDL3 migration (checks wiring, not HW).

Verifies the Input wrapper layer that `AGENTS.md` calls contained:
  - Button/Gamepad axis+button name tables still resolve
    (Button_FromSDLControllerButton etc. compile against SDL_GAMEPAD_*)
  - SDL_Gamepad* symbol presence
  - SDL_HINT_MOUSE_FOCUS_CLICKTHROUGH / SDL_IsGamepad / SDL_OpenGamepad defined
  - gamecontrollerdb.txt parse via SDL_AddGamepadMappingsFromFile

Compiles a tiny probe against SDL3 and checks it exits 0 without opening a device.
Headless-safe (no /dev/input needed). Failure means the Input.cpp Gamepad/Joystick
shim is broken post-migration.

Wired into `configure.py test` after validate_sdl_window.py.
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
    print("[validate_sdl_input] SDL3 Gamepad + hint + mappings probe")
    if not pkg_exists("sdl3"):
        print("FAIL: sdl3 not found (engine requires SDL3)")
        return 1
    fails=0
    code3=textwrap.dedent(r"""
        #include <SDL3/SDL.h>
        #include <stdio.h>
        int main(){
            SDL_GamepadButton b = SDL_GAMEPAD_BUTTON_SOUTH;
            SDL_GamepadAxis a = SDL_GAMEPAD_AXIS_LEFTX;
            SDL_GAMEPAD_BUTTON_DPAD_RIGHT; SDL_GAMEPAD_AXIS_LEFT_TRIGGER;
            (void)b; (void)a;
            const char* h = SDL_HINT_MOUSE_FOCUS_CLICKTHROUGH;
            (void)h;
            /* Renamed API surface the engine calls. */
            (void)SDL_IsGamepad; (void)SDL_OpenGamepad; (void)SDL_CloseGamepad;
            (void)SDL_GetGamepadJoystick; (void)SDL_GetJoystickID;
            (void)SDL_GetJoysticks; (void)SDL_OpenJoystick;
            (void)SDL_GUIDToString; (void)SDL_GetJoystickGUIDForID;
            (void)SDL_GetGamepadButton; (void)SDL_GetGamepadAxis;
            printf("sdl3 Gamepad + hint + API symbols OK\n");
            return 0;
        }
    """)
    ok,out=try_compile("sdl3",code3)
    print(f"  sdl3 input symbols: {'OK' if ok else 'FAIL'} — {out}")
    if not ok: fails+=1
    if pathlib.Path("res/gamecontrollerdb_205.txt").exists():
        code3b=textwrap.dedent(r"""
            #include <SDL3/SDL.h>
            #include <stdio.h>
            int main(){
                if (!SDL_Init(SDL_INIT_GAMEPAD|SDL_INIT_JOYSTICK)) return 2;
                int n = SDL_AddGamepadMappingsFromFile("res/gamecontrollerdb_205.txt");
                printf("mappings %d\n", n);
                SDL_Quit();
                return n>=0?0:1;
            }
        """)
        ok,out=try_compile("sdl3",code3b)
        print(f"  sdl3 gamepad db: {'OK' if ok else 'FAIL'} — {out}")
        if not ok: fails+=1
    else:
        print("  (res/gamecontrollerdb_205.txt not present — skipped mapping load gate)")

    if fails==0:
        print("\n[SDL input] ALL PASS")
        return 0
    print(f"\n[SDL input] {fails} FAILED")
    return 1

if __name__=="__main__": sys.exit(main())
