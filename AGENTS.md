# Codebase Assessment: Limit Theory

## Project Overview
Limit Theory is an open-world space simulation game engine and game project. It is written primarily in C++ and uses Lua for high-level gameplay logic. The project is structured as a core library (`libphx`) and a main executable (`lt`).

## Technology Stack
- **Language:** C++ (Standard C++11)
- **Scripting:** Lua (specifically LuaJIT 5.1)
- **Build System:** CMake
- **Configuration:** Python (`configure.py`)
- **Graphics:** OpenGL, GLEW
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
- **Lua Version:** The `CMakeLists.txt` specifically looks for `luajit-5.1`. Version mismatches may occur.
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
- **"Bad normal at poly" warnings:** Emitted during mesh collision shape generation for certain ship models. Non-fatal.
- **"BSP Incoming Mesh Error: Vertex Position Degenerate":** Occasional degenerate geometry warnings during BSP construction. Non-fatal.
- **Remaining `texture2D` calls (~55):** Found in filter/UI/compute/brush shaders — deprecated but functional in GLSL 130. Low priority.
- **Remaining `gl_FragColor` usage:** In some filter/compute shaders — deprecated but functional in GLSL 130.

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

### Modernization Plan — What To Update

This engine is ~10 years old. The goal is to get it running reliably on modern hardware and make it easier to extend. Below is a prioritized breakdown of what's worth updating and what to leave alone.

#### Worth Doing (High Impact, Low Risk)

1. **Bump `#version` to 330** — The engine hardcodes `#version 130` in `Shader.cpp:27`. GLSL 330 gives proper `in`/`out` support, `texture()` as the standard sampler, and better compiler support on modern GPUs. All shaders are now GLSL 130+ compatible (items 1-2 below are complete).

2. **Replace corrupted texture assets** — Nearly all textures in `res/` are corrupted 130-byte placeholders. Replace with real assets or procedural generation. The engine already handles missing textures gracefully with magenta fallbacks.

3. **Clean up `common.glsl` dead code** — `HIGHQ` is always force-defined (line 16), making `LOWQ` branches dead code. Either remove the `#ifdef HIGHQ` guards entirely (always use the HIGHQ path) or add a runtime toggle. This eliminates confusing GLSL warnings about unused uniforms.

4. **Complete GLSL 130 cleanup** — Replace remaining ~55 `texture2D` calls and `gl_FragColor` usage in filter/UI/compute shaders (deprecated but functional in GLSL 130).

#### Not Worth Doing (High Cost, Low Benefit)

1. **Replacing LuaJIT with Lua 5.4+** — The engine uses LuaJIT's FFI extensively for all C bindings (`ShaderVar`, `Physics`, `Matrix`, etc. via `ffi.cdef`). Standard Lua has no FFI. Migration would require rewriting every FFI binding as a C module. LuaJIT is also faster than standard Lua 5.4 for game workloads.

2. **Rewriting the `#include`/`#autovar` preprocessor** — The custom GLSL preprocessor in `Shader.cpp:129-171` works. Replacing it with a real shader build system (glslc, spirv-cross, spirv-reflect) is a massive refactor for marginal gain. The existing system handles includes, autovars, and caching adequately.

3. **Replacing Bullet Physics** — Already using system Bullet 3.24 successfully. Migrating to a different physics library (Jolt, PhysX) would require rewriting all physics code for no functional gain.

4. **Replacing FMOD** — Proprietary but functional. Replacing with OpenAL or PipeWire would require rewriting the entire audio system. Not a priority for getting the engine running.

5. **Updating C++ standard** — The codebase is C++11. Updating to C++17/20 would require compiler and build system changes with no functional benefit for a game engine of this type.

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
export LD_LIBRARY_PATH=$LD_LIBRARY_PATH:$(pwd)/bin:$(pwd)/libphx/ext/lib/linux64
./bin/lt64r LTheory
```

### Next Steps
1. **Bump `#version` to 330** — Change `versionString` in `Shader.cpp:27` from `"#version 130\n"` to `"#version 330\n"` and verify all shaders compile.
2. **Replace corrupted textures** with real assets or procedural generation to restore visual quality.
3. **Clean up `common.glsl` dead code** — Remove `#ifdef HIGHQ` guards or make them runtime-toggleable.
4. **Extend the engine** for Freelancer-style 3D space environments (procedural nebulae, dust, sectors, etc.).
5. **Update this document** as new milestones are reached.
