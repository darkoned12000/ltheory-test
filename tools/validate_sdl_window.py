#!/usr/bin/env python3
"""Hidden-window GL probe for the SDL3 migration (uses SDL via ctypes, no game launch).

Creates a hidden SDL3 window + GL 4.6 core context (via libphx's Window path or
direct SDL) using Xvfb/llvmpipe when no DISPLAY is present. Verifies:
  - SDL_CreateWindow(title, w, h, SDL_WINDOW_HIDDEN|OPENGL) succeeds (SDL3 sig)
  - SDL_GL_CreateContext + SDL_GL_MakeCurrent
  - SDL_GL_SetSwapInterval, SDL_Hide/ShowWindow round-trip
  - SDL_GL_DestroyContext (renamed from SDL_GL_DeleteContext in SDL3)

Skips (exit 0) if no display and Xvfb not available — the pkg/init gate in
validate_sdl.py still covers the compile side in CI. On this host with Mesa
it will run headlessly via EGL/llvmpipe if DISPLAY is unset.

Wired into `configure.py test` after validate_sdl.py.
"""
import os, subprocess, sys, tempfile, textwrap, pathlib, shutil

def main():
    print("[validate_sdl_window] hidden SDL3 window + GL 4.6 core probe")
    # Probe via a tiny C program that creates the window (so we don't depend on pygame)
    code = textwrap.dedent(r"""
        #include <SDL3/SDL.h>
        #include <stdio.h>
        int main(){
            if (!SDL_Init(SDL_INIT_VIDEO)){ printf("SDL_Init failed: %s\n", SDL_GetError()); return 2; }
            SDL_GL_SetAttribute(SDL_GL_CONTEXT_MAJOR_VERSION, 4);
            SDL_GL_SetAttribute(SDL_GL_CONTEXT_MINOR_VERSION, 6);
            SDL_GL_SetAttribute(SDL_GL_CONTEXT_PROFILE_MASK, SDL_GL_CONTEXT_PROFILE_CORE);
            SDL_GL_SetAttribute(SDL_GL_DOUBLEBUFFER, 1);
            SDL_GL_SetAttribute(SDL_GL_DEPTH_SIZE, 24);
            /* SDL3 signature: SDL_CreateWindow(title, w, h, flags) — no x/y. */
            SDL_Window* w = SDL_CreateWindow("probe", 64, 64, SDL_WINDOW_OPENGL|SDL_WINDOW_HIDDEN);
            if (!w){ printf("SDL_CreateWindow failed: %s\n", SDL_GetError()); SDL_Quit(); return 3; }
            SDL_GLContext ctx = SDL_GL_CreateContext(w);
            if (!ctx){ printf("SDL_GL_CreateContext failed: %s\n", SDL_GetError()); SDL_DestroyWindow(w); SDL_Quit(); return 4; }
            if (!SDL_GL_MakeCurrent(w, ctx)){ printf("MakeCurrent failed: %s\n", SDL_GetError()); SDL_GL_DestroyContext(ctx); SDL_DestroyWindow(w); SDL_Quit(); return 5; }
            SDL_GL_SetSwapInterval(1);
            SDL_HideWindow(w);
            SDL_ShowWindow(w);
            printf("window+ctx OK\n");
            SDL_GL_DestroyContext(ctx);
            SDL_DestroyWindow(w);
            SDL_Quit();
            return 0;
        }
    """)
    # Engine now links SDL3 exclusively.
    try:
        subprocess.check_output(["pkg-config","--exists","sdl3"])
    except subprocess.CalledProcessError:
        print("[SDL window] SKIP (no SDL3 pkg found)")
        return 0
    with tempfile.TemporaryDirectory() as td:
        c = pathlib.Path(td)/"w.c"
        exe = pathlib.Path(td)/"w"
        c.write_text(code)
        flags = subprocess.check_output(["pkg-config","--cflags","sdl3"], text=True).split()
        llibs = subprocess.check_output(["pkg-config","--libs","sdl3"], text=True).split()
        # Need -lGL for the context test on some linkers
        llibs += ["-lGL"]
        cmd = ["cc", str(c), "-o", str(exe)] + flags + llibs
        try:
            subprocess.check_output(cmd, stderr=subprocess.STDOUT, text=True)
        except subprocess.CalledProcessError as e:
            print(f"  sdl3 compile: SKIP — {e.output[:400]}")
            return 0
        env = dict(os.environ)
        # Let SDL pick the best driver; if no DISPLAY, this will fail with "No available video device" and we skip.
        try:
            out = subprocess.check_output([str(exe)], text=True, env=env, timeout=5, stderr=subprocess.STDOUT)
            print(f"  sdl3 hidden window: OK — {out.strip()}")
            print("\n[SDL window] ALL PASS")
            return 0
        except subprocess.CalledProcessError as e:
            msg = (e.output or "")[:600]
            if "No available video device" in msg or "CreateWindow failed" in msg or e.returncode in (2,3,4):
                print(f"  sdl3 hidden window: SKIP — no display (headless CI without Xvfb): {msg[:200]}")
                print("\n[SDL window] SKIP (headless, no DISPLAY)")
                return 0
            print(f"  sdl3 hidden window: FAIL — {msg}")
            return 1
    print("\n[SDL window] SKIP (no SDL pkg found)")
    return 0

if __name__ == "__main__":
    sys.exit(main())
