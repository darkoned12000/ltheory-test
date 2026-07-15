# Limit Theory

Limit Theory is a now-cancelled open world space simulation game.

This repository is the game (not engine) code for the second generation of LT's development, when all work was migrated to C and Lua. For the older, C++/LTSL Limit Theory, see https://github.com/JoshParnell/ltheory-old.

![LT Screenshot](./res/tex2d/screenshot.png)

# Prerequisites

To build Limit Theory, you'll need a few standard developer tools. All of them are available to download for free.

- Python: https://www.python.org/downloads/
- Git: https://git-scm.com/downloads
- Git LFS: https://git-lfs.github.com/
- Visual Studio Community: https://visualstudio.microsoft.com/vs/ (Windows only)
- CMake: https://cmake.org/download/

**Linux users:** You'll also need these system libraries for the engine to run:
```bash
sudo apt install libglu1-mesa-dev libglew-dev libsdl2-dev libfreetype6-dev liblz4-dev libluajit-5.1-dev libbullet-dev
```

# Building

With the above prerequisites installed, open a **Git Bash terminal**.

## Checking out the Repository

First, use `cd` to change directories to the place where you want to download LT.
- `cd ~/Desktop/<path where you want to put the LT source>`

Before doing any other `git` commands, make sure LFS is installed:
- `git lfs install`

You should see `Git LFS initialized` or a similar message. **Important**: if you forget to install and initialize Git LFS, most of the resources will probably be broken, and the whole process will likely fail in strange and mysterious ways. This is a common gotcha with projects that use LFS. Make sure you do the above step!

Now, you can download the repository:

- `git clone --recursive https://github.com/JoshParnell/ltheory.git ltheory`

## Compiling

Once you have the repository, the build process proceeds in two steps (as with other CMake builds): generating the build files, and then building. There is a Python script `configure.py` at the top level of the repository to help you do this easily.

From a terminal in the directory of the checked-out repository, run

- `python configure.py`

This runs CMake to generate the build files. Then, to compile,

- `python configure.py build`

## Running a Lua App

If the compilation is successful, you now have `bin/lt64.exe`, which is the main executable. This program launches a Lua script. The intention was for Limit Theory (and all mods) to be broken into many Lua scripts, which would then implement the gameplay, using script functions exposed by the underlying engine.

To launch a Lua script, you can again use the python helper:
- `python configure.py run`

To run the default script ('LTheory'), or
- `python configure.py run <script_name_without_extension>`

to run a specific script. All top-level scripts are in the `script/App` directory.

# Resurrection Progress & How to Run on Linux

This repository has been resurrected and is now running on Linux with GLSL 330 shaders, fog re-enabled, ambient lighting added, and full deferred rendering pipeline operational. The main game app (`LTheory`) boots, generates a world, spawns ships, and runs the full game loop (rendering, physics, AI) without crashing.

## Prerequisites for Linux

In addition to the standard prerequisites above, you need these system libraries:

- `libglu1-mesa-dev` — OpenGL Utility Library (GLU) bindings; required by CMake for some OpenGL functions.
- `libglew-dev` — GL Extension Wrangler; provides modern OpenGL function pointers and extension loading.
- `libsdl2-dev` — Simple DirectMedia Layer; handles windows, input devices, audio, and timing.
- `libfreetype6-dev` — FreeType font rendering library; used for text display in the UI.
- `liblz4-dev` — LZ4 compression library; used by the engine to compress assets at runtime.
- `libluajit-5.1-dev` — LuaJIT 5.1 interpreter and FFI bindings; the scripting language Limit Theory uses.
- `libbullet-dev` — Bullet physics engine (system version 3.x); handles rigid body dynamics, collisions, etc.

Install them with:
```bash
sudo apt install libglu1-mesa-dev libglew-dev libsdl2-dev libfreetype6-dev liblz4-dev libluajit-5.1-dev libbullet-dev
```

## Building on Linux

The build system is primarily configured for Windows, but has basic Linux support in `CMakeLists.txt`. Run:
```bash
python configure.py
python configure.py build
```

This will produce the engine library and executable in `bin/`.

## Running on Linux

You need to set up your environment variables before running. The engine requires both the main binary directory and the FMOD libraries from `libphx/ext/lib/linux64/`:

```bash
cd <root directory where the ltheory-test code is>
export LD_LIBRARY_PATH=$LD_LIBRARY_PATH:$(pwd)/bin:$(pwd)/libphx/ext/lib/linux64
./bin/lt64r LTheory
```

## Example of the Entire Process on Linux

Open a terminal and run:

```bash
cd ~/Documents/Code_Projects/ltheory-test
export LD_LIBRARY_PATH=$LD_LIBRARY_PATH:$(pwd)/bin:$(pwd)/libphx/ext/lib/linux64
./bin/lt64r LTheory
```

![LTheory App Running](./res/screenshots/Screenshot_1.png)

Replace the path with your actual project location. The `lt64r` executable is the Linux version (the `.exe` files are Windows-only).

## Recommended Roadmap

Based on current state and next steps:

1. **Bump GLSL version to 330** — Already done! All shaders now compile cleanly with proper `layout(location = N)` qualifiers.
2. **Replace corrupted texture assets** — Nearly all textures in `res/` are corrupted placeholder files. Replace with real assets or procedural generation. The engine already handles missing textures gracefully with magenta fallbacks.
3. **Clean up `common.glsl` dead code** — `HIGHQ` is always force-defined, making `LOWQ` branches dead code. Either remove the `#ifdef HIGHQ` guards entirely (always use the HIGHQ path) or add a runtime toggle. This eliminates confusing GLSL warnings about unused uniforms.
4. **Extend the engine** for Freelancer-style 3D space environments — procedural nebulae, dust clouds, sector transitions, and more. The rendering pipeline is solid; this would be pure content creation.
5. **Update documentation** — Add proper license file (MIT or similar), update `AGENTS.md` with current state, and create a CONTRIBUTING guide for anyone wanting to help extend the engine.

## What Was Fixed to Get It Running

- **Bullet Physics ABI mismatch**: The engine was compiling with Bullet 2.87 headers but linking against system Bullet 3.24, causing heap corruption on every physics object allocation. This was fixed by removing the old bullet include path and using system Bullet 3 headers.
- **Texture resilience**: Nearly all texture assets are corrupted placeholder files. The engine now creates magenta fallback textures instead of crashing with `Fatal()`.
- **Shader fixes**: Removed unused `#autovar` declarations that were causing warnings, refactored the G-buffer to use proper GLSL 330 output variables, and modernized shaders from GLSL 120 to GLSL 130 syntax.
- **GLSL version bump**: Upgraded all shaders to GLSL 330 with proper `layout(location = N)` qualifiers for fragment outputs.
- **G-buffer refactor**: Changed the deferred rendering pipeline to use explicit output variables instead of deprecated `gl_FragData[]`, making it compatible with modern OpenGL.
- **Fog re-enabled**: The composite shader now properly applies fog effects (was previously disabled).
- **Ambient lighting added**: Added ambient light contribution to improve overall scene brightness and realism.
- **ui.glsl fix**: Updated the UI vertex shader to use explicit `mProj`/`mView` matrices instead of deprecated built-ins (`gl_ProjectionMatrix`, `gl_ModelViewMatrix`).

## What We Want to Try to Update

- **Bump GLSL version to 330** — The engine currently uses `#version 130`. GLSL 330 gives proper `in`/`out` support and better compiler support on modern GPUs. All shaders are now GLSL 130+ compatible, so this should be straightforward.
- **Replace corrupted texture assets** — Nearly all textures in `res/` are corrupted 130-byte placeholder files (the original asset archive was incomplete). Replace with real assets or procedural generation. The engine already handles missing textures gracefully with magenta fallbacks.
- **Clean up `common.glsl` dead code** — `HIGHQ` is always force-defined, making `LOWQ` branches dead code. Either remove the `#ifdef HIGHQ` guards entirely (always use the HIGHQ path) or add a runtime toggle. This eliminates confusing GLSL warnings about unused uniforms.
- **Complete GLSL 130 cleanup** — Replace remaining ~55 `texture2D` calls and `gl_FragColor` usage in filter/UI/compute shaders (deprecated but functional in GLSL 130).
