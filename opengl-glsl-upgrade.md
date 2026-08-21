# OpenGL / GLSL Upgrade Plan (Full Version Ladder)

Goal: migrate the engine from its current state up to **OpenGL 4.6 / GLSL 460**, one version at a time, keeping the GL context and the shader `#version` in sync at every step. Each stage is tested before moving on. Trouble spots (structural changes that force C++ or shader rewrites) are flagged — they land at **3.3, 4.0, 4.3, and 4.6**.

## Current State (verified 2026-08-21)

| Item | Value | Location |
|---|---|---|
| Context requested | OpenGL **2.1 compatibility** | `src/Main.cpp:15` — `Engine_Init(2, 1)` |
| Shader version | GLSL **130** (GL 3.0 level) | `libphx/src/Shader.cpp:27` — `versionString = "#version 130\n"` |
| Profile mask | `SDL_GL_CONTEXT_PROFILE_COMPATIBILITY` | `libphx/src/Engine.cpp:74-81` |
| Driver capability | Mesa 26.2 → **GL 4.6** available | system ICD |
| GLEW | 2.2.0 (last official release; exposes everything up to 4.6) | system `libglew-dev` |

So the engine is currently running at **2.1 / GLSL 130**, not 3.3 — there is a version skew: the C++ side asks for 2.1, but shaders compile at 3.0 level (Mesa grants a 3.x+ context when 2.1 compat is requested). Stage 1 removes that skew.

## Version Ladder (check off as each stage lands)

GLSL versions map to OpenGL versions: 130→3.0, 140→3.1, 150→3.2, 330→3.3, 400→4.0, 410→4.1, 420→4.2, 430→4.3, 440→4.4, 450→4.5, 460→4.6.

| # | Stage | GL context (`Engine_Init`) | GLSL `#version` | Structural trouble? | C++ work required | Shader work required | Status |
|---|-------|---------------------------|-----------------|---------------------|-------------------|----------------------|--------|
| 0 | Baseline (today) | `(2, 1)` compat | `130` | — | none | none | [x] done |
| 1 | **3.0** | `(3, 0)` compat | `130` (unchanged) | No — low risk | none (context only) | none | [ ] |
| 2 | **3.1** | `(3, 1)` compat | `140` | No — low risk | optional: UBOs become available | optional: adopt uniform buffers | [ ] |
| 3 | **3.2** | `(3, 2)` compat | `150` | No — low risk | none required | optional: geometry shaders, `layout` in/out qualifiers | [ ] |
| 4 | **3.3** ⚠️ | `(3, 3)` compat* | `330` | **YES — core-profile cutover** | keep COMPAT mask until C++ is clean; later flip to CORE | **mandatory**: all ~73 `gl_FragColor`/`gl_FragData[]` → explicit `out vec4`; legacy texture fns → `texture()`/`textureLod()` | [ ] |
| 5 | **4.0** ⚠️ | `(4, 0)` core | `400` | **YES — last legacy removals** | flip profile to CORE (all C++ must be modern VBO path) | subroutines/atomics available; any remaining compute-like passes need explicit outputs | [ ] |
| 6 | **4.1** | `(4, 1)` core | `410` | No — low risk | none required | optional: explicit uniform locations, `textureGather` | [ ] |
| 7 | **4.2** | `(4, 2)` core | `420` | No — low risk | none required | optional: image load/store, dual-source blending | [ ] |
| 8 | **4.3** ⚠️ | `(4, 3)` core | `430` | **YES — compute/SSBO era** | add `glDispatchCompute` plumbing if migrating legacy compute passes | optional: rewrite `computeAO`-style passes as native `.comp` + SSBOs | [ ] |
| 9 | **4.4** | `(4, 4)` core | `440` | No — low risk | none required | optional: sparse texture access, non-uniform derivatives | [ ] |
| 10 | **4.5** | `(4, 5)` core | `450` | No — low risk | none required | optional: transform-feedback stream/mode qualifiers, I/O interning | [ ] |
| 11 | **4.6** ⚠️ | `(4, 6)` core | `460` | **YES — final gate** | verify GLEW exposes full 4.6; robust-buffer-access checks | final deprecation sweep: zero legacy syntax anywhere | [ ] |

\* Stage 4 keeps the COMPATIBILITY mask on purpose: it lets us bump GLSL to 330 (core-profile language) while any straggler C++ calls still work, then flip to CORE at stage 5 once everything is verified.

### What makes each trouble spot a trouble spot

- **3.3 / GLSL 330:** the core profile drops every deprecated fixed-function built-in. Any shader still using `gl_FragColor`, `gl_FragData[]`, or legacy texture functions fails to compile. This is the big shader migration (see checklist below). Vertex-side built-ins (`gl_Vertex`, `gl_MultiTexCoord*`) are **already gone** — all vertex shaders read real attributes now.
- **4.0 / GLSL 400:** last of the legacy removals land; safe to flip the context to CORE profile, which removes immediate mode from the driver entirely. C++ must be 100% on the VBO path (it is — `Draw.cpp` was already rewritten).
- **4.3 / GLSL 430:** compute shaders and SSBOs become real. The engine's legacy "compute" fragment passes (`computeAO`, etc.) can be migrated to native `.comp` + `glDispatchCompute`, or left as-is (they still compile).
- **4.6 / GLSL 460:** final gate — SPIR-V support, robust buffer access. No forced shader syntax changes, but this is where the full deprecation sweep and GLEW capability verification happen.

## Shader Migration Checklist (for Stage 4)

Counts verified 2026-08-21: **73** fragment shaders use `gl_FragColor`/`gl_FragData[]`; **38** shader files still call legacy texture functions.

### A. Fragment outputs (`gl_FragColor` / `gl_FragData[]` → `out vec4`)
Each of the ~73 fragment shaders needs an explicit output:
- UI/filter/effect/compute passes: declare `out vec4 outColor;` (or a named output) and write to it.
- Deferred material passes: already done via `#include deferred` (`fragData0/1/2`) — verify only, no edits expected.

### B. Texture functions
- `texture2D(...)` → `texture(...)` (~55 calls across the 38 files)
- `textureCubeLod(...)` → `textureLod(...)`
- `textureCube(...)` → `texture(...)`

### C. Vertex shaders — DONE (no action needed)
All vertex shaders already use `vertex_position`/`vertex_normal`/`vertex_uv` attributes; zero `gl_Vertex`/`gl_MultiTexCoord*` remain in `res/shader/vertex/`.

### D. Immediate mode — DONE (no action needed)
`libphx/src/Draw.cpp` was fully rewritten to VBOs (interleaved scratch buffer, per-draw bind/unbind). No `glBegin`/`glVertex` remains.

## Per-Stage Procedure

For **every** stage (1–11):

1. Branch: `git checkout -b upgrade-gl<MAJOR>_<MINOR>`
2. Edit the two values together — context and shader version must move in sync:
   - `src/Main.cpp:15` → `Engine_Init(<M>, <m>);`
   - `libphx/src/Shader.cpp:27` → `versionString = "#version <NNN>\n";`
3. At stage 4 only: complete the Shader Migration Checklist **before** flipping `#version`.
4. At stage 5 only: flip `SDL_GL_CONTEXT_PROFILE_MASK` to `SDL_GL_CONTEXT_PROFILE_CORE` in `libphx/src/Engine.cpp` (after confirming zero legacy C++ GL calls remain).
5. Rebuild and run:
   ```bash
   python3 configure.py build && ./run.sh LTheory
   ```
6. Watch stderr for `CreateGLShader: Failed to compile shader` — any hit means a shader still uses syntax removed by the new GLSL version; fix that shader, rebuild, repeat.
7. Visual QA sweep: skybox, stars, G-buffer materials, UI/HUD, post-processing filters, effects. Confirm no missing/broken passes.
8. Commit on green. Check off the stage in the table above and update `AGENTS.md`.

## Known Failure Modes & Rollback

- **`'gl_FragColor' undeclared` / `'gl_Vertex' undeclared`** at first shader compile → a shader still uses legacy built-ins removed by the new GLSL version. Grep for the symbol, fix, rebuild.
- **Green screen / half-black frame** → attribute-location mismatch between C++ bind code and shader `in` declarations (locations: 0=pos, 1=normal, 2=uv per `Shader.cpp:91-93`). 
- **Context creation returns NULL / engine aborts at boot** → driver refused the requested version/profile; check `SDL_GL_GetError()` output and Mesa DRI version.
- **Rollback:** revert the two-line change (`Main.cpp` + `Shader.cpp`) plus any profile-mask flip, rebuild, re-run. Each stage is independent — a failed stage rolls back to the previous green commit without touching earlier stages.

#### Affected Shader Files
- Fragment shader files containing legacy `gl_FragColor` output: ~73 files under `res/shader/fragment/**`. Run `rg -l 'gl_FragColor'` to list them; each needs an explicit `out vec4 outColor;` declaration and replacement of the `gl_FragColor` assignments.
- Texture function files using legacy texture calls: ~38 files. Use `rg -l 'texture2D('` and similar patterns to identify them; replace with `texture(...)`, `textureLod(...)`, or `textureCube...`.
+ *Add a tip:* If you hit a green‑screen after bumping to 4.0, first run the `glBegin` test path in `Draw.cpp` (should be dead code) – sometimes drivers still expect it for internal state.
