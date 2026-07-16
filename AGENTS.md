# Codebase Assessment: Limit Theory

## Project Overview
Limit Theory is an open-world space simulation game engine and game project. It is written primarily in C++ and uses Lua for high-level gameplay logic. The project is structured as a core library (`libphx`) and a main executable (`lt`).

## Technology Stack
- **Language:** C++17 (was C++11; bumped to C++17 in `libphx/script/build/Shared.cmake`)
- **Scripting:** Lua (LuaJIT 2.1.x, Lua 5.1 ABI — see LuaJIT Status note)
- **Build System:** CMake (minimum `VERSION 3.16`, set in both `CMakeLists.txt` and `libphx/CMakeLists.txt`)
- **Configuration:** Python (`configure.py`)
- **Graphics:** OpenGL (context requested as **2.1 compatibility profile** from `src/Main.cpp:15` → `Engine_Init(2,1)`; shaders compiled at **GLSL `#version 130`** / GL 3.0 level via `libphx/src/Shader.cpp:27`), GLEW (**2.3** system lib, exposes GL up to 4.6)
- **Input/Windowing:** SDL2
- **Physics:** Bullet Physics
- **Audio:** FMOD
- **Compression:** LZ4
- **Fonts:** FreeType

## Codebase Structure
- `src/`: Main entry point and high-level game code.
- `libphx/`: The core engine library.
    - `include/`: Engine headers.
    - `src/`: Engine implementation.
    - `ext/`: Third-party dependencies (headers and pre-compiled binaries).
    - `script/`: Engine-related scripts and build helpers.
- `res/`: Game resources (textures, models, etc.).
- `script/`: Gameplay Lua scripts.

## Current State & Observations
- The project appears to be unfinished/cancelled.
- Build system is primarily configured for Windows, but has basic Linux support in `CMakeLists.txt`.
- Many dependencies are provided as pre-compiled binaries in `libphx/ext/lib/linux64`.
- The `configure.py` script is a wrapper around CMake.

## Potential Challenges for Linux Build
- **Dependencies:** Ensuring all system-level dependencies (`GL`, `GLEW`, `SDL2`, `freetype`, `luajit`) are installed and discoverable by CMake.
- **Library Paths:** The project uses a hardcoded rpath to `../ext/lib/linux64`. We need to ensure this aligns with where the binaries are actually located at runtime.
- **Lua Version:** On Linux the build links the system `luajit-5.1` package (libphx/CMakeLists.txt:92), which is LuaJIT 2.1.x. The bundled `lua51.dll`/headers under `libphx/ext` are Windows-only and are 2.1.0-beta3. No Linux LuaJIT `.so` is bundled — the runtime loader finds the system library via `LD_LIBRARY_PATH`.
- **Compiler Flags:** Aggressive optimization flags (`-O3`, `-msse4`) are used; compatibility with the host CPU must be verified.

## Recommended Roadmap
1. **Environment Setup:** Install all required development headers on the Linux host.
2. **Build Fixes:** Modify `CMakeLists.txt` or `configure.py` if necessary to correctly find system libraries.
3. **First Compilation:** Attempt a clean build using `cmake` and `make`.
4. **Runtime Debugging:** Fix any shared library loading issues (e.g., `LD_LIBRARY_PATH`).
5. **Verification:** Launch the engine with a default Lua script.
6. **Documentation:** Create a guide for adding new 3D environments and extending the engine.

## Resurrection Progress & Modernization Plan (July 2026)

### Current Status
- **Engine Boot:** SUCCESS. The engine boots on Linux and executes Lua scripts.
- **Rendering:** SUCCESS. Full deferred rendering pipeline operational (G-buffer, lighting, post-processing).
- **Physics:** SUCCESS. `Physics.Create()` and the full Bullet Physics pipeline work correctly with system Bullet 3.24.
- **LTheory App:** SUCCESS. The main game app (`LTheory`) boots, generates a world, spawns ships, and runs the full game loop (rendering, physics, AI) without crashing.
- **Asset Loading:** IMPROVING. Corrupted texture placeholders have been replaced with real assets. The engine still handles any remaining missing textures gracefully with magenta fallbacks.
- **Shaders:** COMPLETE. GLSL 130 modernization applied across all critical shaders. G-buffer refactored to use `out vec4` instead of deprecated `gl_FragData[]`. Fog re-enabled. Ambient lighting added.

### Build & Link Fixes (Completed)
1. **CMake version:** Bumped `cmake_minimum_required` from 3.0.2 to 3.5 in both root and `libphx/CMakeLists.txt`.
2. **System dependencies installed:** `libglu1-mesa-dev libglew-dev libsdl2-dev libfreetype6-dev liblz4-dev libluajit-5.1-dev libbullet-dev`.
3. **Pre-compiled Bullet libs relocated:** Moved `libphx/ext/lib/linux64/Bullet*.so` to `bullet_backup/` so the system Bullet 3.24 libraries are used instead of the bundled Bullet 2.87 binaries.
4. **`libphx/CMakeLists.txt` link configuration:** Removed `target_link_directories` for `ext/lib`, switched FMOD/fmodstudio to absolute paths, added `LinearMath` to the link list (required by system Bullet).
5. **FMOD symlinks:** Created symlinks (`libfmod.so.10 -> libfmod.so`, etc.) in `ext/lib/linux64/` so the FMOD runtime loader finds the correct soname.
6. **`libphx64.so` symlink:** Created `libphx64.so -> libphx64r.so` in `bin/` for the Lua FFI loader.
7. **SDL version check disabled:** Commented out the SDL version assertion in `libphx/src/Engine.cpp` to allow newer SDL2 (2.32) to work.
8. **CProfileManager removed:** Commented out `CProfileManager::dumpAll()` in `libphx/src/Physics.cpp` (not available in system Bullet 3).
9. **LuaJIT version check disabled:** Modified `script/jit/dump2.lua` to skip strict version check.

10. **LuaJIT on Linux is 2.1.x:** The build links the system `luajit-5.1` package (libphx/CMakeLists.txt:92), which is **LuaJIT 2.1.1761786044** (OpenResty-maintained branch, Lua 5.1 ABI). The bundled `lua51.dll`/headers under `libphx/ext` are Windows-only (and are 2.1.0-beta3). There is no bundled Linux LuaJIT `.so`. See "LuaJIT Status" below.
11. **Global shadowing warnings fixed:** `Namespace.LoadInline('Game')` (Main.lua:20) injected every `Game.*` submodule into `_G`, and `Game.SocketType`/`Game.Socket` collided with the existing `PHX.FFI.SocketType`/`PHX.FFI.Socket` globals. Renamed `Game/SocketType.lua` → `Game/SocketKind.lua` and `Game/Socket.lua` → `Game/SocketObj.lua` (and updated the `require(...)` calls) so the injected keys no longer clash.
12. **Runtime Lua errors fixed (regression from a bad prior refactor):** `Game.SocketType` returns the `LTheory_SocketType` table directly, so `SocketType.LTheory_SocketType` was `nil`, and `Sockets.lua` referenced a non-existent `GameSocket` global. Corrected all references to use the module tables directly (e.g. `require('Game.SocketKind')`, local `LTheory_Socket`).
13. **Mesh degenerate-geometry warnings fixed:** Added `Shape:cleanup(eps)` (welds coincident/near-coincident vertices and drops degenerate/bowtie polys) and call it from `Shape:finalize()` before triangulation. This eliminates the `Bad normal at poly` and `BSP Incoming Mesh Error: Vertex Position Degenerate` warnings at their source. The verbose `getFaceNormal` print is now gated behind `Config.gen.debug` (default `false`). Ships build and display cleanly.
14. **`LD_LIBRARY_PATH` no longer required:** Added `$ORIGIN`-based `RUNPATH` to `lt64r` and `libphx64r.so` (CMake `BUILD_RPATH`/`INSTALL_RPATH` in `CMakeLists.txt` and `libphx/CMakeLists.txt`), and made `ffi.load` resolve `libphx64.so` via an absolute path derived from the script location (`libphx/script/ffi/libphx.lua`). Also fixed the bundled `libfmod.so`, which carried an executable-stack flag (`GNU_STACK = RWE`) that modern kernels reject on `dlopen` — its `p_flags` was patched to `RW` in place. Added `run.sh` (launcher) and `bootstrap.sh` (one-command install+configure+build) at the repo root. Bumped `cmake_minimum_required` to 3.16 and the C++ standard to C++17 (`libphx/script/build/Shared.cmake`).

### Session: Asteroid Interaction, Targeting & Cleanup (July 2026)

Made asteroids actually destructible and the world clean up after them:

1. **Asteroids are now destructible** (`script/Game/Entities/Asteroid.lua`): they call `addHealth(scale*10, 0)` and register an `Event.Destroyed` handler `fragment` that spawns 2–4 smaller child asteroids (cascading) plus an explosion/dust burst. Previously asteroids had **no health**, so projectiles hit them and did nothing.
2. **Entity GC added** (`System:sweepDestroyed` in `script/Game/Entities/System.lua`): each `update` removes children that are `deleted` or have `health <= 0`, pulling their rigid bodies out of physics. Without this a "destroyed" asteroid stayed in the world and you could still crash into (and die on) it.
3. **Ramming damage** (`System:handleRamming`): iterates `physics:getNextCollision()`, maps bodies → entities via `Entity.fromRigidBody`, and deals symmetric damage above a relative-speed threshold.
4. **Targeting / lock fixed** (`script/Game/Controls/HUD.lua`): `drawTargets` now always computes the lock candidate (was gated behind `Config.ui.showTrackers`, which `Config.Local.lua` sets false — so `T` did nothing). `drawLock` clears the lock when the target dies, and draws a health bar over the locked entity.
5. **Pulse damage rebalanced** (`Config.App.lua` `pulseDamage` 5 → 40) and asteroid health lowered (`scale*10`) so a few hits actually destroy a rock.
6. **UI triangle shader bug fixed** (`res/shader/fragment/ui/triangle.glsl`): it wrote to read-only `uniform` `p1/p2/p3` and used `vec3 pos` in `vec2` math → GLSL compile error that aborted the game the first time anything drew a triangle (e.g. the lock arrow). Now uses local `q1/q2/q3` and `pos.xy`.
7. **`RigidBody_SetLinearVelocity`** added (C++ `libphx/src/RigidBody.cpp`, header, and Lua FFI bindings) so fragments can be kicked outward (`Entity:setVelocity`).
8. **Console damage log** added (`Config.debug.damageLog` in `Config.App.lua`, used in `Health.lua`).
9. **Comments added** throughout `Asteroid.lua`, `Health.lua`, `System.lua` (ramming/sweep/spawn), `HUD.lua` (targeting), and the triangle shader, to document the destruction/targeting flow for new contributors.

### LuaJIT Status (as of July 2026)
- **Linux runtime:** LuaJIT **2.1.1761786044** via system `libluajit-5.1-dev` (OpenResty branch). This is a 2.1.x line, **not** the original 2.0.1. If 2.0.1 was used at some point it was a Windows-only bundled binary; nothing in the current tree pins 2.0.1.
- **ABI:** Lua 5.1 ABI — the engine relies heavily on LuaJIT FFI (`ffi.cdef`, `ffi.load`) for `ShaderVar`, `Physics`, `Matrix`, etc. Standard Lua (5.4) has no FFI, so a switch would mean rewriting every binding. Not recommended.
- **Caveat:** `dump2.lua`'s version check is disabled as a stopgap. The system OpenResty 2.1 diverges slightly from upstream Mike Pall 2.1-beta3; FFI binding behavior should be smoke-tested after any LuaJIT version change. For reproducible builds, consider building LuaJIT from a pinned source rather than depending on the distro package.

### The Bullet Physics Fix (Root Cause)
The engine was compiling with **Bullet 2.87 headers** from `libphx/ext/include/bullet/` but linking against the **system Bullet 3.24 library** (`libbullet-dev:amd64 3.24+dfsg-5`). This ABI mismatch caused heap corruption (`malloc(): invalid size`) on every Bullet object allocation in `Physics_Create()`.

**Fix applied:**
- Renamed `libphx/ext/include/bullet/` to `bullet_old_2.87/` so old headers are no longer found by the compiler.
- Removed `target_include_directories (phx PUBLIC "ext/include/bullet")` from `libphx/CMakeLists.txt`.
- Added `target_include_directories (phx SYSTEM PUBLIC "/usr/include/bullet")` so system Bullet 3 headers are used, and their internal relative includes (`LinearMath/btVector3.h`, etc.) resolve correctly.
- Rebuilt. The code compiled cleanly against Bullet 3.24 headers and now links against the matching library — no ABI mismatch.

### Texture Resilience Fix
Nearly all texture assets in `res/` are corrupted 130-byte placeholder files (the original asset archive was incomplete). The engine's `Tex2D_LoadRaw` called `Fatal()` on load failure, killing the entire process.

**Fix applied:**
- `libphx/src/Tex2D_Load.cpp`: Changed `Fatal()` to `Warn()` — missing images are logged but don't abort.
- `libphx/src/Tex2D.cpp`: `Tex2D_Load()` now creates a 1x1 magenta fallback texture when image data is NULL.
- `libphx/src/TexCube.cpp`: `TexCube_Load()` now creates fallback cubemap faces instead of aborting when individual faces fail to load.

### Remaining Non-Fatal Warnings
- **`envMap` in `global.glsl`:** `HIGHQ` is always defined (forced in `common.glsl:16`), so the `#else` branch using `envMap` is dead code. The GLSL compiler correctly optimizes it out. Harmless.
- **Remaining `texture2D` calls (~55):** Found in filter/UI/compute/brush shaders — deprecated but functional in GLSL 130. Low priority.
- **Remaining `gl_FragColor` usage:** In some filter/compute shaders — deprecated but functional in GLSL 130.

### Fixed Warnings (Non-Fatal, Now Resolved)
- **"Bad normal at poly":** Was emitted by `Shape:getFaceNormal` for degenerate/bowtie polys generated during ship mesh construction. Resolved by the `Shape:cleanup()` weld + degenerate-drop pass in `Shape:finalize()` (build fix #13). The offending print is gated behind `Config.gen.debug`.
- **"BSP Incoming Mesh Error: Vertex Position Degenerate":** Was emitted by `Mesh_Validate` (C) for coincident vertices in the finalized ship mesh. Resolved by the same vertex-welding step in `Shape:cleanup()`.

### Shader Fixes (Completed)
The deferred rendering shaders had numerous `#autovar` declarations for uniforms that the GLSL compiler optimized out because they were unused in the final compiled shader. Each `#autovar` line registers a variable for automatic ShaderVar stack binding, but if the compiler drops the uniform, `glGetUniformLocation` returns -1 and a warning fires.

**Root cause of `Shader_BindVariables` warnings:**
1. **Dead code branches:** `common.glsl:16` force-defines `#define HIGHQ`, making `#else` branches dead code. Shaders declaring `#autovar` for variables only used in dead branches got warnings.
2. **Disabled fog:** `composite.glsl` had `fog *= 0.0`, making `worldDir`, `irMap`, and the vertex shader's `mViewInv`/`mProjInv` computations dead code.
3. **Genuinely unused autovars:** Several shaders declared `#autovar` for variables they never referenced (e.g., `skybox.glsl` declared `irMap` but only used `envMap`).

**Fixes applied:**

| Shader | Removed `#autovar` | Reason |
|--------|-------------------|--------|
| `vertex/worldray.glsl` | `mView`, `mProj` | Only `mViewInv`/`mProjInv` are used |
| `fragment/skybox.glsl` | `irMap` | Only `envMap` is used |
| `fragment/material/metal.glsl` | `irMap`, `envMap` | Only `eye` is used (deferred G-buffer output) |
| `fragment/material/asteroid.glsl` | `envMap`, `irMap` | Only `eye` is used |
| `fragment/light/point.glsl` | `eye` | Not used in shader body |
| `fragment/light/composite.glsl` | `envMap`, `eye` | Only `irMap` is used |
| `fragment/light/global.glsl` | `envMap` | Dead code (`HIGHQ` always defined) |

### G-buffer Refactor (Completed)
**`#include deferred` now uses `out vec4` instead of `gl_FragData[]`:**
- `deferred.glsl`: Declares `out vec4 fragData0/1/2` (mapped to color attachments 0-2)
- `composite.glsl`, `global.glsl`, `point.glsl`: Updated to use `fragData0` instead of `gl_FragData[0]`
- Material shaders unchanged (they use `setAlbedo()` etc. which write to `fragData0/1/2` internally)
- New shaders can now declare their own `out vec4 outColor` without conflicting with G-buffer output

### GLSL 130 Modernization (Completed)
All critical shaders have been updated from GLSL 120 to GLSL 130 syntax:

**Include files:**
- `vertex.glsl`: `attribute` → `in`, `varying` → `out`
- `fragment.glsl`: `varying` → `in`
- `fog.glsl`: `textureCubeLod` → `textureLod`
- `texturing.glsl`: `texture2D` → `texture`
- `fdm.glsl`: `texture2D` → `texture`

**Light shaders:**
- `composite.glsl`: `varying` → `in`, `texture2D` → `texture`, `textureCubeLod` → `textureLod`, `textureCube` → `texture`, re-enabled fog, added ambient lighting
- `global.glsl`: `varying` → `in`, `texture2D` → `texture`, `textureCubeLod` → `textureLod`
- `point.glsl`: `varying` → `in`, `texture2D` → `texture`

**Material shaders:**
- `ore.glsl`: `textureCubeLod` → `textureLod`
- `uv_metal.glsl`: `textureCubeLod` → `textureLod`
- `planet.glsl`: `textureCubeLod` → `textureLod`
- `devmatenv.glsl`: `textureCubeLod` → `textureLod`
- `triplanar.glsl`: `textureCubeLod` → `textureLod`, removed `#extension GL_ARB_shader_texture_lod : require`

**Other shaders:**
- `skybox.glsl`: `textureCube` → `texture`
- `starbg.glsl`: `textureCubeLod` → `textureLod`
- `dustcloud.glsl`: `textureCubeLod` → `textureLod`
- `nebula_emit.glsl`/`nebula_absorb.glsl`: `textureCube` → `texture`
- `skybox_spheremap.glsl`: `textureCube`/`textureCubeLod` → `texture`/`textureLod`

**Vertex shaders:**
- `worldray.glsl`, `identity.glsl`, `wrapped.glsl`: `varying` → `out`

**13 fragment shaders:** `varying` → `in` (ptracer, skybox_dynamic, ptracer_out, terrain, filter/*, compute/*)

### Key Architectural Notes
The engine prepends `#version 130\n` to all shaders via `glShaderSource(self, 2, srcs, 0)` in `libphx/src/Shader.cpp:63-68`. Shards must NOT contain their own `#version` directive. The `#include` and `#autovar` directives are custom preprocessor extensions handled by `GLSL_Preprocess()` in `Shader.cpp:129-171` — `#include` is recursively resolved via `GLSL_Load()`, and `#autovar` lines are stripped from the source and registered as automatic ShaderVar bindings.

**GLSL include chain:** `vertex.glsl` declares all standard uniforms (`mView`, `mProj`, `mViewInv`, `mProjInv`, `eye`, `mWorld`, `mWorldIT`) and the `VS_BEGIN`/`VS_END` macros. `fragment.glsl` declares `eye`, `mWorldIT`, `envMap`, `irMap`, `starColor`, `starDir`, and the `FRAGMENT_CORRECT_DEPTH` macro. `common.glsl` defines `HIGHQ`/`LOWQ`, `farPlane`, and `Fcoef`.

### Graphics / OpenGL Context (how GL is initialized)

This is the most undocumented part of the engine's graphics stack. Captured here so new features can be added safely.

- **Context request is explicit and pinned in code** (`libphx/src/Engine.cpp:71-81`, inside `Engine_Init`):
  ```cpp
  SDL_GL_SetAttribute(SDL_GL_CONTEXT_MAJOR_VERSION, glVersionMajor);   // = 2
  SDL_GL_SetAttribute(SDL_GL_CONTEXT_MINOR_VERSION, glVersionMinor);   // = 1
  SDL_GL_SetAttribute(SDL_GL_CONTEXT_PROFILE_MASK,
                      SDL_GL_CONTEXT_PROFILE_COMPATIBILITY);
  // ... plus ACCELERATED_VISUAL, 8/8/8 color, DOUBLEBUFFER, DEPTH_SIZE 24
  ```
  The major/minor come from the caller `Engine_Init(2, 1)` in `src/Main.cpp:15`. So the engine **requests an OpenGL 2.1 compatibility-profile context**.
- **Window + context creation** happens in `libphx/src/Window.cpp:18-19` (`SDL_CreateWindow` then `SDL_GL_CreateContext`), and `OpenGL_Init()` (`libphx/src/OpenGL.cpp:6-12`) runs `glewInit()` immediately after.
- **Shaders are compiled at GLSL `#version 130`** (`libphx/src/Shader.cpp:27`) — that is **OpenGL 3.0** GLSL. There is a **version skew**: the C++ side requests a 2.1 context, but the shaders target 3.0. On Linux this works in practice because GLX/Mesa grant a 3.x+ context when a 2.1 compat profile is requested; on stricter drivers it could fail to compile `#version 130` shaders. This is the root reason the docs say "bump to 330" — the *context* should be raised to match (or exceed) the *shader* level.
- **GLEW is system 2.3** (link line `libphx/CMakeLists.txt:88`; header confirms `GLEW_VERSION_MAJOR 2` / `MINOR 3`). GLEW 2.3 exposes **every** OpenGL extension through GL 4.6, so any modern GL feature (compute shaders, SSBOs, tessellation, bindless textures, PBR) is already callable — GLEW will have it loaded after `glewInit()`. No GLEW upgrade is needed to use new GL features.

#### Adding new OpenGL / GLSL features later
1. **Raise the context to match the shaders first** — change `Engine_Init(2, 1)` in `src/Main.cpp:15` to e.g. `Engine_Init(3, 3)` (or `4, 5` for compute). Keep `SDL_GL_CONTEXT_PROFILE_COMPATIBILITY` so legacy calls in `OpenGL.cpp`/`OpenGL_Init` still work. This makes the GL version explicit and predictable instead of driver-dependent.
2. **Bump the shader `#version`** in `libphx/src/Shader.cpp:27` from `"#version 130\n"` to `"#version 330\n"` (or higher) so new GLSL syntax (`layout(location=)`, `imageLoad/Store`, compute) is available. The shaders are already 130-clean, so 330 is low-risk.
3. **GLEW needs no change** — just call the new GL function; GLEW 2.3 has it. Add `glGetError()` checks via the existing `OpenGL_CheckError()` macro if unsure.
4. **Note on linking:** GL/GLEW are linked as bare `-lGL -lGLEW` (`libphx/CMakeLists.txt:87-88`), resolved from system paths. For a more robust/self-documenting build you *could* add `find_package(OpenGL REQUIRED)` + `find_package(GLEW REQUIRED)` and use the imported targets `OpenGL::GL` / `GLEW::GLEW`, but it is not required for error-free builds.

#### GLSL 330 Bump — Attempted & Reverted (July 2026)

An attempt was made to bump `Engine_Init(2, 1)` → `(3, 3)` (`src/Main.cpp:15`) and `#version 130` → `#version 330` (`libphx/src/Shader.cpp:27`) together. **It builds but aborts at runtime** on the first shader compile, and has been **reverted** to keep the stable baseline. Findings, so the next attempt has a real roadmap:

- **Root cause:** GLSL 330 is a *core*-profile GLSL that removes every deprecated fixed-function built-in the engine's shaders still use. The first failure is `CreateGLShader: Failed to compile shader: 'gl_MultiTexCoord0' undeclared / 'gl_Vertex' undeclared` (during `computeAO` at boot).
- **The migration is NOT a one-line bump — it is a renderer migration.** Scope discovered:
  - **4 vertex shaders** use fixed-function built-ins (`gl_Vertex`, `gl_MultiTexCoord0`, `gl_ModelViewMatrix`, `gl_ProjectionMatrix`): `res/shader/vertex/ui.glsl`, `identity.glsl`, `ui3D.glsl`, `worldray.glsl`. These must be rewritten to read generic `in` attributes and multiply by explicit `mView`/`mProj` uniforms.
  - **~73 fragment shaders** use `gl_FragColor` / `gl_FragData[]` — must become explicit `out vec4`.
  - **`libphx/src/Draw.cpp`** does all UI/debug drawing via **18 `glBegin`/`glVertex` immediate-mode blocks**, which do not exist in a core profile at all. This is a **C++ rewrite to VBOs/VAOs**, and is the hardest part.
- **What's already modern (good news):** `libphx/src/Mesh.cpp` — the actual 3D geometry path — already submits generic attributes via `glVertexAttribPointer(0/1/2, ...)` for position/normal/uv (`Mesh.cpp:220-226`) and draws with `glDrawElements`. Only the *vertex shaders* need to switch from `gl_Vertex` to `layout(location=0) in vec3 ...` (locations 0=pos, 1=normal, 2=uv). The immediate-mode `glBegin` calls in `Mesh.cpp` are only in `Mesh_DrawNormals` (debug).
- **Why it "builds but crashes":** we kept `SDL_GL_CONTEXT_PROFILE_COMPATIBILITY`, so the driver still grants a compatibility context (C++ `glBegin` keeps working), but the *shaders* at `#version 330` reject the legacy built-ins. Worst of both worlds.

**Recommended incremental path for a future attempt (do NOT bump `#version` until all shaders are migrated):**
1. Migrate the 4 vertex shaders to `layout(location=)` `in` attributes + `mView`/`mProj` uniforms, while still on `#version 130` (130 supports this syntax). Verify each still renders.
2. Convert all `gl_FragColor`/`gl_FragData[]` fragment shaders to `out vec4` (the G-buffer material shaders are already done via `deferred.glsl`).
3. Rewrite `Draw.cpp` immediate-mode drawing to a small VBO/VAO helper (position + uv + color streams).
4. Only then bump `Shader.cpp:27` to `#version 330` **and** `src/Main.cpp:15` to `Engine_Init(3, 3)` together, and switch the profile to core if desired.
5. Rebuild + run `LTheory`; watch stderr for `CreateGLShader: Failed to compile shader`.

### Draw.cpp VBO Rewrite — DONE & Verified (July 2026)

Step 3 above is **complete**. `libphx/src/Draw.cpp` no longer uses any deprecated immediate mode (`glBegin`/`glVertex`/`glTexCoord`). Every `Draw_*` function now:

- Accumulates vertices into a static interleaved scratch buffer `[x, y, z, u, v]` (5 floats).
- Uploads via `glBufferData` to a single dynamic VBO (`s_vbo`) per draw call.
- Binds attributes with the **same pattern as `Mesh.cpp`**: `Draw_Bind()` enables `glVertexAttribArray(0)` (position) and `(2)` (uv) and points them at the VBO; `Draw_Unbind()` disables + unbinds — mirroring `Mesh_DrawBind`/`Mesh_DrawUnbind`. **No persistent VAO** (a first draft using a static VAO caused green-screen / half-black regressions because the VAO's recorded attrib state interacted badly with `Mesh_DrawUnbind`'s `glDisableVertexAttribArray(0/1/2)`; the per-draw bind/unbind pattern matches what already works in this codebase).
- Expands `GL_QUADS` → 2×`GL_TRIANGLES` and `GL_POLYGON` → triangle fan on the CPU, exactly matching the old immediate-mode expansion.

**Verified:** rebuilt + ran `LTheory` — clean boot, no shader/GL errors/warnings, full scene renders correctly (ships, asteroids, stars, HUD; fly/shoot/blow-up-asteroids all work). 

**Step 1 (vertex shader migration) is ALSO DONE.** The 4 vertex shaders now read real attributes instead of legacy built-ins:
- `res/shader/vertex/ui.glsl`: `gl_Vertex`/`gl_MultiTexCoord0` → `vertex_position`/`vertex_uv`.
- `res/shader/vertex/identity.glsl`: same, plus added `#include vertex`.
- `res/shader/vertex/worldray.glsl`: same (`vertex_position.xy` / `vertex_uv`).
- `res/shader/vertex/ui3D.glsl`: already modern (uses `vertex_position` via `VS_BEGIN`).
A `grep` confirms **zero** remaining `gl_Vertex`/`gl_MultiTexCoord` in `res/shader/vertex/`. These run correctly at `#version 130` (compat profile) where `Shader.cpp` binds `vertex_position→loc0`, `vertex_normal→loc1`, `vertex_uv→loc2` (`Shader.cpp:91-93`), matching `Draw_Bind`'s loc 0/2 setup.

**Key bug fixed during verification:** the first `Draw_Expand` implementation expanded quads/polygons **in place** (forward, `s_verts[out++] = ...`). For a flush with multiple quads this corrupted later source vertices (write destination `6*q` overlapped unread source `4*q+3` once `q>=1`), producing "out-of-sync" triangles / picture-in-picture artifacts. Fix: expand into a **separate scratch buffer `s_expand`** then `memcpy` back (`libphx/src/Draw.cpp`), so reads never clobber writes. Required `#include <cstring>`.

**Engine current state (July 2026):** runs correctly at **GLSL 130** with the OpenGL **2.1 compat context** (`Engine_Init(2,1)`, `Shader.cpp:27` = `#version 130`). This is the stable, working baseline.

**Remaining for a future 330 bump (deferred — not needed for gameplay):**
- Step 2: convert ~73 fragment shaders from `gl_FragColor`/`gl_FragData[]` to explicit `out vec4` (G-buffer material shaders via `deferred.glsl` already done; the 73 are UI/filter/effect/compute passes). ~35 of those also still call `texture2D` (deprecated but legal in 130).
- Then bump `Engine_Init(2,1)`→`(3,3)` and `#version 130`→`330` **together** (attempted separately before and reverted — see "GLSL 330 Bump — Attempted & Reverted"). Rebuild + watch stderr for `Failed to compile shader`.

### Gameplay Systems (Lua) — Asteroids, Damage, Targeting

These are the systems that make "blow up an asteroid" work. They live entirely in `script/Game/`.

#### Damage & Destruction (the event model)
- Every damageable entity calls `Entity:addHealth(max, rate)` (in `script/Game/Components/Health.lua`). `rate=0` means no regen.
- To hurt something: `entity:damage(amount, source)`. When health hits 0 it fires `Event.Destroyed(source)`. This is the **only** way objects die — projectiles (`Pulse.lua`) and ramming (`System.handleRamming`) both just call `:damage()`.
- Listen for death with `entity:register(Event.Destroyed, handler)`. Asteroids use this to fragment (`script/Game/Entities/Asteroid.lua`).
- Console debug: set `Config.debug.damageLog = true` in `script/Config.App.lua` to print every hit as `[DAMAGE] entity#id took X ...`.

#### Asteroids (`script/Game/Entities/Asteroid.lua`)
- `Asteroid = subclass(Entity, ...)` builds a procedurally-generated mesh (`Gen.Asteroid(seed)`, cached per seed), a rigid body, and a visible LOD mesh.
- Health = `max(15, scale*10)` — intentionally low so a few weapon hits or one ram destroys it.
- Destruction handler `fragment(self, source)`: if `scale > minFragmentScale` (0.5) it spawns 2–4 child asteroids at half scale with a random outward kick; always spawns an explosion/dust burst (`Entities.Explosion`, which fades on its own).
- The child asteroids are themselves full `Asteroid`s, so they cascade (shoot a fragment → it fragments again → ... → too small → just explodes).

#### Entity cleanup / "why dead things vanished"
- The engine has **no automatic entity GC**. `Entity:delete()` only sets `self.deleted = true`; `Health.damage` only flips health to 0. Historically a "destroyed" asteroid kept its rigid body in the physics world (you could still crash into it).
- Fixed in `System:sweepDestroyed()` (called each `System:update`): it removes any child that is `deleted` or has `health <= 0`. `removeChild` triggers `RemovedFromParent`, which for a RigidBody calls `physics:removeRigidBody`, pulling it out of the simulation. Iterate backwards because `removeChild` shrinks the array.

#### Ramming (`System:handleRamming`)
- After `physics:update`, `getNextCollision()` yields each contacting rigid-body pair. Map bodies → entities via `Entity.fromRigidBody`, compute relative speed, and if `> rammingMinSpeed` (25) deal symmetric damage `(relSpeed - 25) * 2.0` to both. Enough damage destroys the asteroid (→ fragment → swept).

#### Targeting & HUD (`script/Game/Controls/HUD.lua`)
- `self.targets` is a `TrackingList` (`script/Util/TrackingList.lua`) of every alive, damageable entity in the system.
- `drawTargets` draws brackets (gated by `Config.ui.showTrackers`) AND picks the lock candidate = alive entity nearest screen center within 128px. Press **`T`** (`ShipBindings.LockTarget`) to lock it; **`G`** clears.
- `drawLock` draws a direction arrow + a colored health bar (`cur / max`) over the locked target. If the target is destroyed it clears the lock.
- NOTE: `Config.Local.lua` sets `Config.ui.showTrackers = false`, which hides brackets but locking still works. Set it to `true` to see target brackets.

#### Building a scene full of asteroids
In `script/App/LTheory.lua:generate()` (or any app):
```lua
self.system:spawnAsteroidField(2000, 20)   -- count, oreCount
```
Or spawn one manually:
```lua
local a = Entities.Asteroid(seed, scale)
a:setPos(Vec3f(x, y, z))
self.system:addChild(a)                     -- addChild = put it in the live world
```
Asteroid `scale` drives both visual size and health. See `System:spawnAsteroidField` for field-clustering logic.

#### Shaders & interaction
- Shaders live in `res/shader/` (vertex + fragment `.glsl`). Loaded at runtime via `Cache.Shader(vs, fs)` (e.g. `Cache.Shader('identity', 'sdf/asteroid')`). The engine prepends `#version 130` and runs a custom preprocessor (`#include`, `#autovar`).
- To draw UI: `UI.DrawEx.*` (`Rect`, `TextAdditive`, `Tri`, `Arrow`, `Wedge`, ...). `DrawEx.Arrow`/`Tri` compile `fragment/ui/triangle.glsl` — a UI triangle SDF. That shader had a latent GLSL bug (writing to read-only uniforms + `vec3`/`vec2` mismatch) that crashed the first time anything drew a triangle; it is now fixed.
- To create a new shader: copy an existing pair, `#include` the shared headers (`vertex.glsl`/`fragment.glsl`), declare uniforms with `uniform` in an include and bind them with `#autovar`, write to `out vec4 fragData0/1/2` for deferred material passes or your own `out vec4` for UI/effect passes. Keep GLSL 130 syntax (`in`/`out`/`texture()`).

### Modernization Plan — What To Update

This engine is ~10 years old. The goal is to get it running reliably on modern hardware and make it easier to extend. Below is a prioritized breakdown of what's worth updating and what to leave alone.

#### Worth Doing (High Impact, Low Risk)

 1. **Bump `#version` to 330** — The engine hardcodes `#version 130` in `Shader.cpp:27`. GLSL 330 gives proper `in`/`out` support, `texture()` as the standard sampler, and better compiler support on modern GPUs. All shaders are now GLSL 130+ compatible (items 2-4 below are complete).
    - **Note:** `README.md` previously claimed "GLSL 330 already done" — that is inaccurate. `Shader.cpp` still emits `#version 130`, and shaders use `out vec4 fragData0/1/2` (G-buffer) rather than `layout(location=N)` qualifiers. The GLSL 120→130 modernization is complete; the 330 bump remains a TODO.
    - **Context skew to fix alongside it:** the C++ side requests an **OpenGL 2.1 compatibility-profile context** (`Engine_Init(2, 1)` in `src/Main.cpp:15`), but the shaders are GLSL 3.0 (`#version 130`). Before/with the 330 bump, raise the requested context to `Engine_Init(3, 3)` (or higher) so the context matches the shader level. See the "Graphics / OpenGL Context" section above for the full picture.

2. **Replace corrupted texture assets** — Nearly all textures in `res/` are corrupted 130-byte placeholders. Replace with real assets or procedural generation. The engine already handles missing textures gracefully with magenta fallbacks.

3. **Clean up `common.glsl` dead code** — `HIGHQ` is always force-defined (line 16), making `LOWQ` branches dead code. Either remove the `#ifdef HIGHQ` guards entirely (always use the HIGHQ path) or add a runtime toggle. This eliminates confusing GLSL warnings about unused uniforms.

4. **Complete GLSL 130 cleanup** — Replace remaining ~55 `texture2D` calls and `gl_FragColor` usage in filter/UI/compute shaders (deprecated but functional in GLSL 130).

5. **Pin / verify LuaJIT 2.1** — The Linux runtime is the distro's OpenResty LuaJIT 2.1.1761786044, which diverges slightly from upstream Mike Pall 2.1-beta3. For reproducible builds, build LuaJIT from a pinned source, and run an FFI smoke-test pass (Physics/Matrix/ShaderVar bindings) whenever the LuaJIT version changes. The `dump2.lua` version check is currently disabled as a stopgap.

#### Not Worth Doing (High Cost, Low Benefit)

1. **Replacing LuaJIT with Lua 5.4+** — The engine uses LuaJIT's FFI extensively for all C bindings (`ShaderVar`, `Physics`, `Matrix`, etc. via `ffi.cdef`). Standard Lua has no FFI. Migration would require rewriting every FFI binding as a C module. LuaJIT is also faster than standard Lua 5.4 for game workloads.

2. **Rewriting the `#include`/`#autovar` preprocessor** — The custom GLSL preprocessor in `Shader.cpp:129-171` works. Replacing it with a real shader build system (glslc, spirv-cross, spirv-reflect) is a massive refactor for marginal gain. The existing system handles includes, autovars, and caching adequately.

3. **Replacing Bullet Physics** — Already using system Bullet 3.24 successfully. Migrating to a different physics library (Jolt, PhysX) would require rewriting all physics code for no functional gain.

4. **Replacing FMOD** — Proprietary but functional. Replacing with OpenAL or PipeWire would require rewriting the entire audio system. Not a priority for getting the engine running.

 5. **Updating C++ standard** — Already done: bumped from C++11 to C++17 in `libphx/script/build/Shared.cmake`. No further standard bump is worth doing for a game engine of this type.

6. **Migrating from CMake** — The build system works. Replacing with Meson, Bazel, or similar is churn without gain.

#### Shader Portability Rules (For Future Reference)

When writing or adapting shaders for this engine:

- **No `#version` directives** — The engine prepends `#version 130\n` automatically via `Shader.cpp:63-68`.
- **Use `#include` for shared code** — `vertex.glsl` (uniforms, VS_BEGIN/VS_END), `fragment.glsl` (eye, envMap, irMap), `common.glsl` (constants), `deferred.glsl` (G-buffer output), `gamma.glsl`, `color.glsl`, `math.glsl`.
- **Use `#autovar` for auto-bound uniforms** — Registers a variable for automatic ShaderVar stack binding. The variable must also be declared as `uniform` in an include file.
- **G-buffer output via `#include deferred`** — Use `setAlbedo()`, `setNormal()`, `setDepth()`, `setRoughness()`, `setMaterial()`. These write to `fragData0/1/2` (mapped to color attachments 0-2). You cannot mix `out vec4` with these.
- **Use `in`/`out` not `varying`** — GLSL 130+ syntax. `varying` is deprecated but functional.
- **Use `texture()` not `texture2D()`** — GLSL 130 standard sampler function.
- **Use `textureLod()` not `textureCubeLod()`** — GLSL 130 standard LOD function for cubemaps.

### How to Run
```bash
cd /home/rhague/Documents/Code_Projects/ltheory-test
./run.sh LTheory
```
`run.sh` sets `LD_LIBRARY_PATH` as a safety net and `cd`s to the repo root. The engine
no longer requires `LD_LIBRARY_PATH`: `$ORIGIN`-based `RUNPATH` resolves the C++ library
chain, and `libphx/script/ffi/libphx.lua` loads `libphx64.so` by absolute path. You can
also run `./bin/lt64r LTheory` directly from the repo root without any env var.

### Next Steps
1. **Bump `#version` to 330** — Change `versionString` in `Shader.cpp:27` from `"#version 130\n"` to `"#version 330\n"` and verify all shaders compile.
2. **Replace corrupted textures** with real assets or procedural generation to restore visual quality.
3. **Clean up `common.glsl` dead code** — Remove `#ifdef HIGHQ` guards or make them runtime-toggleable.
4. **Complete GLSL 130 cleanup** — Replace remaining `texture2D`/`gl_FragColor` in filter/UI/compute shaders.
5. **Extend the engine** for Freelancer-style 3D space environments (procedural nebulae, dust, sectors, etc.).
6. **Pin LuaJIT** — Build LuaJIT 2.1 from a pinned source for reproducible Linux builds; smoke-test FFI bindings after any version bump.
7. **Update this document** as new milestones are reached.
