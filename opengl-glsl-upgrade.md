# OpenGL / GLSL Upgrade Plan (Full Version Ladder)

Goal: migrate the engine from its current state up to **OpenGL 4.6 / GLSL 460**, one version at a time, keeping the GL context and the shader `#version` in sync at every step. Each stage is tested before moving on. Trouble spots (structural changes that force C++ or shader rewrites) are flagged — they land at **3.3, 4.0, 4.3, and 4.6**.

## Current State (verified 2026-08-21, updated 2026-08-22 to 3.2/150)

| Item | Value | Location |
|---|---|---|
| Context requested | OpenGL **3.2 compatibility** | `src/Main.cpp:15` — `Engine_Init(3, 2)` |
| Shader version | GLSL **150** (GL 3.2) | `libphx/src/Shader.cpp:27` — `versionString = "#version 150\n"` |
| Profile mask | `SDL_GL_CONTEXT_PROFILE_COMPATIBILITY` | `libphx/src/Engine.cpp:74-81` |
| Driver capability | Mesa 26.2 → **GL 4.6** available | system ICD |
| GLEW | 2.2.0 (last official release; exposes everything up to 4.6) | system `libglew-dev` |

Engine at **3.2/150** (phase 3) — `3.1/140` → `3.2/150` (`150` `layout` in/out qualifiers, geometry shaders optional, `gl_FragColor` still valid at `150` compat).

## Version Ladder (check off as each stage lands)

GLSL versions map to OpenGL versions: 130→3.0, 140→3.1, 150→3.2, 330→3.3, 400→4.0, 410→4.1, 420→4.2, 430→4.3, 440→4.4, 450→4.5, 460→4.6.

| # | Stage | GL context (`Engine_Init`) | GLSL `#version` | Structural trouble? | C++ work required | Shader work required | Status |
|---|-------|---------------------------|-----------------|---------------------|-------------------|----------------------|--------|
| 0 | Baseline (today) | `(2, 1)` compat | `130` | — | none | none | [x] done |
| 1 | **3.0** | `(3, 0)` compat | `130` (unchanged) | No — low risk | none (context only) | none | [x] done 2026-08-22 (via 3.1 bump, context 3.0 verified) |
| 2 | **3.1** | `(3, 1)` compat | `140` | No — low risk | optional: UBOs become available | optional: adopt uniform buffers | [x] done 2026-08-22 — `Engine_Init(3,1)` `versionString 140` clean, `gl_FragColor` at 140 compat OK |
| 3 | **3.2** | `(3, 2)` compat | `150` | No — low risk | none required | optional: geometry shaders, `layout` in/out qualifiers | [x] done 2026-08-22 — `Engine_Init(3,2)` `versionString 150` clean, `gl_FragColor` at 150 compat OK (`moderngl` 150 legacy still valid) |
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

- **3.3 / GLSL 330:** the core profile drops every deprecated fixed-function built-in. Any shader still using `gl_FragColor`, `gl_FragData[]`, or legacy texture functions fails to compile. This is the big shader migration (see checklist below). Vertex-side built-ins `gl_Vertex`/`gl_MultiTexCoord*` are gone, but `gl_ProjectionMatrix`/`gl_ModelViewMatrix` remain in `ui.glsl`/`ui3D.glsl` `res/shader/vertex:2` — need `Viewport` `mProjUI` + `starbg` `discard` + `farplane` `w` + `MasterControl` `nil`.
- **4.0 / GLSL 400:** last of the legacy removals land; safe to flip the context to CORE profile, which removes immediate mode from the driver entirely. C++ must be 100% on the VBO path (it is — `Draw.cpp` was already rewritten).
- **4.3 / GLSL 430:** compute shaders and SSBOs become real. The engine's legacy "compute" fragment passes (`computeAO`, etc.) can be migrated to native `.comp` + `glDispatchCompute`, or left as-is (they still compile).
- **4.6 / GLSL 460:** final gate — SPIR-V support, robust buffer access. No forced shader syntax changes, but this is where the full deprecation sweep and GLEW capability verification happen.

## Shader Migration Checklist (for Stage 4)

Counts verified 2026-08-21 at `313ddc9`: **75** `gl_FragColor`/`gl_FragData[]` (`rg -l 'gl_FragColor' res/shader/fragment` 75, `58` `texture2D` + `18` `texture1D`/`texture3D`/`textureCube` = `76` legacy texture calls total), `2` `gl_ProjectionMatrix` remains in `res/shader/vertex/ui.glsl:6` `ui3D.glsl:15`.

### A. Fragment outputs (`gl_FragColor` / `gl_FragData[]` → `out vec4`)
Each of the ~75 fragment shaders needs `layout(location=0) out vec4 outColor;` + `gl_FragColor→outColor` (or `fragData0/1/2` via `res/shader/include/deferred.glsl:21-23` already `out vec4 fragData0/1/2` — keep, add `layout(location=0/1/2)` for `330` and `libphx/src/Shader.cpp:98-101` `glBindFragDataLocation(0,"outColor"/"fragData0")` fallback).
- UI/filter/effect/compute: `layout(location=0) out vec4 outColor;`
- Deferred: `layout(location=0) out vec4 fragData0;` etc — verify `res/shader/fragment/material/*` `res/shader/fragment/light/*` use `setAlbedo()` not `gl_FragColor`.

### B. Texture functions
- `texture2D(...)` → `texture(...)` (~58)
- `textureCube(...)` → `texture(...)` , `textureCubeLod(...)` → `textureLod(...)`
- `texture1D(...)` → `texture(...)` (`res/shader/fragment/gen/nebula.glsl:80` `lutR` `res/shader/fragment/filter/colorgrade.glsl:23` `curve1`) and `texture3D(...)` → `texture(...)` (`res/shader/fragment/compute/occlusion_sdf.glsl:26` `sdf`, `res/shader/include/scattering2.glsl:27` `cloudNoise`) — `76` total, not `38`.

### C. Vertex shaders — NOT DONE (2 remain)
`res/shader/vertex/ui.glsl:6` `gl_ProjectionMatrix*gl_ModelViewMatrix` and `ui3D.glsl:15` need `mProj/mView` via `libphx/src/Viewport.cpp:51-89` `mProjUI/mViewUI` `ShaderVar` push (`isWindow` `T(-1,1)*S(2/sx)`) + `res/shader/include/vertex.glsl:22` `mViewUI/mProjUI` + `#autovar`.
`res/shader/vertex/farplane.glsl:1` `farPlane*vertPos,w=0` `mView/mProj` `z=w` clips half `Box3(-1,1)` faces at `330` core (`w=-viewZ` negative) → skybox missing squares/boxes moving when flying.

### D. Immediate mode — DONE
`libphx/src/Draw.cpp` VBO done. Also need `starbg` `res/shader/fragment/starbg.glsl:7` `if(a<0.02) discard` for `Additive` `Box3` star quads (`script/Gen/Starfield.lua:18` `distance 1e6` `radius 1/30*distance`) otherwise `0+skybox` black squares.

### E. Lua — `MasterControl` nil
`script/Game/Controls/MasterControl.lua:16-21` `playerShip:getParent():hasDockable()` nil when ship `deleted` (`System:sweepDestroyed` `script/Game/Entities/System.lua:48`) → `xpcall` crash `841200697710436919ULL` `BSP Underflow` `libphx/src/Triangle.cpp:84` seed. Guard `if not playerShip/getParent/hasDockable then return false`.

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

- **`'gl_FragColor' undeclared` / `'gl_Vertex' undeclared` / `texture1D undeclared`** at first shader compile → a shader still uses legacy built-ins removed by the new GLSL version. Grep for the symbol, fix, rebuild. At `313ddc9` `75` `gl_FragColor`, `58` `texture2D` + `18` `texture1D/3D` remain.
- **White background black models** → deferred `fragData0/1/2` without `layout(location=)` + `glBindFragDataLocation` `libphx/src/Shader.cpp:98` `res/shader/include/deferred.glsl:21` → `texAlbedo` black, `texLighting` 0.
- **Black screen purple streaks left corner / green screen / half-black** → `ui.glsl:6` `gl_ProjectionMatrix` at `330` core + `Viewport` not pushing `mProjUI` `libphx/src/Viewport.cpp:51` → `mProj/mView` `0` → UI `Draw.Rect` offscreen, attribute mismatch `Shader.cpp:91-93` locations 0/1/2.
- **Skybox missing squares / boxes moving when flying / stars through skybox** → `farplane.glsl:22` `farPlane*vertPos,w=0` `w=-viewZ` negative for 3/6 `Box3` faces behind → `w<=0` clip at `330` core (was `COMPAT` `130` `gl_ProjectionMatrix` fixed-function `w` handled); `skybox.glsl:11` `texture(envMap,V)` `envMap` `TexCube_Generate` `gen/nebula` `texture1D` fallback magenta `libphx/src/TexCube.cpp:118` + `starbg` additive `Box3` star quads `Gen/Starfield.lua:18` `0+skybox` black squares without `discard a<0.02` `starbg.glsl:12`.
- **`BSP Incoming Mesh Error: Vertex Position Underflow` + `MasterControl.lua:19` `hasDockable` nil** → `System:sweepDestroyed` deleted `playerShip:getParent()` nil `841200697710436919ULL` seed, `Triangle.cpp:84` `edgeLen<0.75*PLANE_THICKNESS_EPSILON`.
- **Context creation returns NULL / engine aborts at boot** → driver refused the requested version/profile; check `SDL_GL_GetError()` output and Mesa DRI version.
- **Rollback:** revert the two-line change (`Main.cpp` + `Shader.cpp`) plus any profile-mask flip, rebuild, re-run. Each stage is independent — a failed stage rolls back to the previous green commit without touching earlier stages.

#### Affected Shader Files
- Fragment shader files containing legacy `gl_FragColor` output: ~73 files under `res/shader/fragment/**`. Run `rg -l 'gl_FragColor'` to list them; each needs an explicit `out vec4 outColor;` declaration and replacement of the `gl_FragColor` assignments.
- Texture function files using legacy texture calls: ~38 files. Use `rg -l 'texture2D('` and similar patterns to identify them; replace with `texture(...)`, `textureLod(...)`, or `textureCube...`.
+ *Add a tip:* If you hit a green‑screen after bumping to 4.0, first run the `glBegin` test path in `Draw.cpp` (should be dead code) – sometimes drivers still expect it for internal state.
