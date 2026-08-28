# Codebase Assessment: Limit Theory

## Project Overview
Limit Theory is an open-world space simulation game engine/game project, written primarily in C++ with Lua for high-level gameplay logic. Structured as a core library (`libphx`) and a main executable (`lt`).

## Technology Stack
- **Language:** C++17 (bumped from C++11)
- **Scripting:** LuaJIT 2.1.x, Lua 5.1 ABI — FFI bindings go through `ffi.cdef`/`ffi.load`; do not replace with standard Lua
- **Build System:** CMake (`configure.py` wrapper; floor `VERSION 3.16`)
- **Graphics:** OpenGL **4.6 core** context + GLSL **460 core** shaders, GLEW 2.2.0 (system), one global VAO bound for the process lifetime in `OpenGL_Init`
- **Input/Windowing:** SDL2; Physics: Bullet; Audio: FMOD (bundled); Compression: LZ4; Fonts: FreeType
- **Bitness:** All binaries and native libs are **64-bit (x86-64)** — verified (`bin/lt64r`, `bin/libphx64r.so`, FMOD/Bullet under `libphx/ext/lib/linux64`). No 32-bit artifacts present.

## Current State — LADDER COMPLETE at GL 4.6 / GLSL 460 CORE (2026-08-22)
The version ladder in `opengl-glsl-upgrade.md` is fully done (stages 0–11 GREEN). The only remaining work before merging to main is the **Pre-Main Checklist** at the bottom of that file.

- Context: `Engine_Init(4,6)` → GL 4.6 core (`src/Main.cpp:15`, `libphx/src/Engine.cpp`); Mesa grants it; GLEW prints a `[GL] ... glew-4.6 yes/no` flag on boot.
- Shaders compiled at `#version 460 core` (`libphx/src/Shader.cpp:27`). The engine prepends this to every shader, so `.glsl` files must NOT contain their own `#version`.
- Zero legacy tokens across shaders AND C++.

### Load-bearing architecture (read before touching rendering code)
1. **Global VAO** (`OpenGL_Init`) — core profile has no default VAO; one is created after `glewInit()` and bound forever. All draw attrib state lands in it.
2. **No program-0 draws** (Stage 5 Finding B): Mesa core rasterizes nothing silently when no program is bound. **Every draw must run under an explicitly started program.** `Renderer.lua`'s `present/presentAll/startPostEffects-downsample` wrap their quads in `Cache.Shader('ui','filter/identity')`.
3. **Eager autovar trap** (Stage 3 Finding 1): `#autovar` uniforms upload once, at `Shader_Start`, not per-draw. A pass that starts its shader before pushing its render-target viewport bakes in window matrices. Start the shader inside the first RT push. Matrix-free passes (`identity.glsl`) are immune.

### Offline validator (safety net for `.glsl` edits)
`python3.13 configure.py test` → `tools/validate_glsl.py`: compiles+links every vs/fs headlessly via moderngl/EGL at the engine's GLSL level, auto-parsed from `Shader.cpp`. EGL validates at `<NNN> core` (stricter than runtime). **Always run before any shader edit.** A typo now fails at configure time. Invoke as `python3.13` — `configure.py` uses `sys.executable`, and the system `python3` can't run it.

## Gameplay Systems (Lua) — Asteroids, Damage, Targeting
Live in `script/Game/`. The event model: every damageable entity calls `Entity:addHealth(max, rate)` (`rate=0` = no regen); hurt via `entity:damage(amount, source)`; health 0 fires `Event.Destroyed`; listen with `entity:register(Event.Destroyed, handler)`.
- **Asteroids** build a procedurally generated mesh + rigid body + visible LOD mesh (cached per seed). Health = `max(15, scale*10)`. Death spawns 2–4 smaller children (cascading) + an explosion burst. `System:sweepDestroyed()` (each update) removes dead/`deleted` children and pulls their bodies out of physics — without it you could still crash into a "destroyed" rock.
- **Ramming** (`System:handleRamming`) maps rigid-body collisions → entities, deals symmetric damage above a relative-speed threshold.
- **Targeting/HUD**: `drawTargets` locks the nearest entity within 128px of screen center; `T`/`G` lock/clear; `drawLock` clears on death and draws a health bar over the target.
- Spawn a field: `self.system:spawnAsteroidField(2000, 20)`. Manual: build an `Entities.Asteroid(seed, scale)`, `setPos(Vec3f(...))`, then `self.system:addChild(a)`.

## Post-4.6 Modernization Backlog — Pre-Main Checklist
Ordered by expected impact. Engine runs fully functional now; these are feature investments, not correctness fixes. Branch off main once the ladder merges.

- **Required before merge (DONE):**
  1. **Point-light shadow maps** — DONE. Per-light Depth32F ortho shadow maps + PCF test in `point.glsl`, rendered and fed from `GameView.lua:renderShadows` (commit `df8c1a8`). Tuning via `render.shadow.{bias,scale,radius}` settings.
  2. **Explicit uniform locations on `deferred.glsl`** — DONE. `fragData0/1/2` now carry `layout(location=0/1/2)` (2026-08-27); matches existing `layout(location=0)` convention used by the effect shaders. Validator: 118 OK, 0 FAIL.

- **Deferred TODOs (non-blocking, tracked post-merge):**
  3. **SPIR-V shader loading (4.6 feature)** — TODO (deferred). Offline-compiled loads via `glShaderBinary`/`glSpecializeShader`; low priority, driver support varies, and the engine's custom `#include`/`#autovar` preprocessor must be replicated in an offline build tool. Net benefit is startup-time only (shaders compile once at boot, then cached as programs), and the offline validator already catches compile errors. Full rationale in chat assessment. Not required for merge.
  4. **Replace corrupted texture assets** — TODO (deferred; user-excluded). Most `res/` textures are real; only `res/texcube/{city,sunset}` + `res/tex2d/image/{vader,cantinaband}` are 130-byte placeholders (upstream `JoshParnell/ltheory` ships the same). Fix = procedural sky/env cubemaps. Not required for merge.

Full detail (with trigger conditions) is in `opengl-glsl-upgrade.md`'s Pre-Main Checklist + the "Post-4.6 hardening" section below.

## Post-4.6 Hardening Already Done
- **Validator restored**: `moderngl pytest` installed; `configure.py test` runs headlessly (llvmpipe/EGL). Fails fast on any shader typo.
- **Graceful runtime shader failure** (`74f717a`): C++ non-abort + cached-good program fallback + in-game overlay naming the bad pass. A broken shader degrades instead of crashing.
- **GPU-quality settings panel** (`Config.gpu`, Renderer seeds bloom/sharpen from it at startup) — weak hardware drops expensive post-passes instead of shipping broken; visually testable via the planet's atmosphere rim glow.
- **Planet spawn**: `System:spawnPlanet()` returns its handle; app pushes the ship clear of the surface if too close (bearing preserved).

## Gameplay / Build Notes Worth Knowing
- **Bullet** (`AGENTS.md` "The Bullet Physics Fix"): engine compiles against **system Bullet 3** headers/libs (ABI-matched). The stale bundled Bullet 2.87 headers (`bullet_old_2.87/`, 221 files) were removed — no build/code references remained.
- **Texture resilience**: missing images log a warning + use a 1x1 magenta fallback instead of aborting (was `Fatal()`).
- **Run:** `./run.sh LTheory` from the repo root; no `LD_LIBRARY_PATH` needed (`$ORIGIN` RUNPATH + absolute-path FFI loader).

## Deferred TODOs (non-blocking, post-merge)
- **SPIR-V shader loading** — Pre-Main #3. Deferred; custom `#include`/`#autovar` preprocessor must be replicated offline. Startup-time win only.
- **Procedural sky/env cubemaps** — Pre-Main #4. Deferred; generate the 6 cube faces procedurally (gradient + stars/noise) and drop into `res/texcube/city/` + `res/texcube/sunset.jpg`.

## Modern Engine Upgrade Opportunities (post-merge roadmap)
The GL/GLSL ladder is complete (GL 4.6 core) and the engine is fully 64-bit. Beyond the Pre-Main checklist, modern-PC improvements worth pursuing (visuals + procedural creation, in the spirit of Josh's vision):
- **HDR + tonemapping** (ACES/AgX + exposure) on the lit buffer — biggest single visual win; deferred outputs are currently LDR-composited.
- **SSAO / GTAO from depth** — now feasible since point-light shadows already write a depth buffer; cheap ambient occlusion for asteroids/planets.
- **Bindless textures / texture arrays** for the deferred material path — fewer state changes with many materials.
- **GPU-driven / indirect draws** (`glMultiDrawElementsIndirect`) for large asteroid/entity counts.
- **Volumetric atmosphere / planetary scattering** — upgrade the current rim-glow for the planet.
- **Procedural content expansion**: L-system stations, SDF planets with biome terrain, procedural nebulae — the engine already has the SDF `Gen/` pipeline + compute particles; extend the generators.
- **Library currency**: SDL2→SDL3 (optional), refresh bundled FMOD, keep Bullet 3 + LuaJIT.
- **Multithreaded render/submit** — job-system the draw submission (larger lift).
- **Vulkan** — the true modern target, but a full renderer rewrite; not recommended until the GL path is fully settled.

