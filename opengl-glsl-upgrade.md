# OpenGL / GLSL Upgrade Plan (Full Version Ladder)

Goal: migrate the engine from its current state up to **OpenGL 4.6 / GLSL 460**, one version at a time, keeping the GL context and the shader `#version` in sync at every step. Each stage is tested before moving on. Trouble spots (structural changes that force C++ or shader rewrites) are flagged — they land at **3.3, 4.0, 4.3, and 4.6**.

## Current State (verified 2026-08-21, updated 2026-08-22 to 3.2/150)

| Item | Value | Location |
|---|---|---|
| Context requested | OpenGL **3.2 compatibility** | `src/Main.cpp:15` — `Engine_Init(3, 2)` |
| Shader version | GLSL **150 compat** (GL 3.2) | `libphx/src/Shader.cpp:27` — `versionString = "#version 150 compatibility\n"` |
| Profile mask | `SDL_GL_CONTEXT_PROFILE_COMPATIBILITY` | `libphx/src/Engine.cpp:74-81` |
| Driver capability | Mesa 26.2 → **GL 4.6** available | system ICD |
| GLEW | 2.2.0 (last official release; exposes everything up to 4.6) | system `libglew-dev` |

Engine at **3.2/150** (phase 3, GREEN 2026-08-22 after skybox fix). The `compatibility`
token on `#version` is deliberate: from GLSL 150 on, a bare `#version NNN` means **core**
semantics per spec; Mesa tolerated legacy builtins anyway, but the explicit token keeps
them guaranteed until the stage-5 CORE flip.

## Version Ladder (check off as each stage lands)

GLSL versions map to OpenGL versions: 130→3.0, 140→3.1, 150→3.2, 330→3.3, 400→4.0, 410→4.1, 420→4.2, 430→4.3, 440→4.4, 450→4.5, 460→4.6.

| # | Stage | GL context (`Engine_Init`) | GLSL `#version` | Structural trouble? | C++ work required | Shader work required | Status |
|---|-------|---------------------------|-----------------|---------------------|-------------------|----------------------|--------|
| 0 | Baseline (today) | `(2, 1)` compat | `130` | — | none | none | [x] done |
| 1 | **3.0** | `(3, 0)` compat | `130` (unchanged) | No — low risk | none (context only) | none | [x] done 2026-08-22 (via 3.1 bump, context 3.0 verified) |
| 2 | **3.1** | `(3, 1)` compat | `140` | No — low risk | optional: UBOs become available | optional: adopt uniform buffers | [x] done 2026-08-22 — `Engine_Init(3,1)` `versionString 140` clean, `gl_FragColor` at 140 compat OK |
| 3 | **3.2** | `(3, 2)` compat | `150 compat` | **YES — more than expected**: `gl_ProjectionMatrix` rejected at 150 (even w/ COMPAT ctx) forced the `ui`/`ui3D` migration + `Viewport` `mProjUI/mViewUI`; `TexCube_Generate` autovar-order fix | done: ui/ui3D modernization, all legacy texture fns → `texture()`, `starbg` discard, `MasterControl` guards, TexCube shader-start reorder | see Stage 3 notes below | [x] done 2026-08-22 — 5 clean runs, skybox/stars/HUD verified vs 140 baseline |
| 4 | **3.3** ⚠️ | `(3, 3)` compat* | `330 compatibility` | **YES — core-language cutover** | keep COMPAT mask until C++ is clean; later flip to CORE | checklist item A only: ~73 `gl_FragColor` files → `layout(location=0) out vec4` (B/C/D/E already done) | [ ] |
| 5 | **4.0** ⚠️ | `(4, 0)` core | `400` | **YES — last legacy removals** | flip profile to CORE (all C++ must be modern VBO path) | subroutines/atomics available; any remaining compute-like passes need explicit outputs | [ ] |
| 6 | **4.1** | `(4, 1)` core | `410` | No — low risk | none required | optional: explicit uniform locations, `textureGather` | [ ] |
| 7 | **4.2** | `(4, 2)` core | `420` | No — low risk | none required | optional: image load/store, dual-source blending | [ ] |
| 8 | **4.3** ⚠️ | `(4, 3)` core | `430` | **YES — compute/SSBO era** | add `glDispatchCompute` plumbing if migrating legacy compute passes | optional: rewrite `computeAO`-style passes as native `.comp` + SSBOs | [ ] |
| 9 | **4.4** | `(4, 4)` core | `440` | No — low risk | none required | optional: sparse texture access, non-uniform derivatives | [ ] |
| 10 | **4.5** | `(4, 5)` core | `450` | No — low risk | none required | optional: transform-feedback stream/mode qualifiers, I/O interning | [ ] |
| 11 | **4.6** ⚠️ | `(4, 6)` core | `460` | **YES — final gate** | verify GLEW exposes full 4.6; robust-buffer-access checks | final deprecation sweep: zero legacy syntax anywhere | [ ] |

\* Stage 4 keeps the COMPATIBILITY mask on purpose: it lets us bump GLSL to 330 (core-profile language) while any straggler C++ calls still work, then flip to CORE at stage 5 once everything is verified.

## Stage 3 (3.2 / 150) Troubleshooting Notes — READ BEFORE STAGE 4+

These two findings cost a full debug session; they apply to **every** later stage.

### Finding 1: `#autovar` uniforms are uploaded ONCE, eagerly, at `Shader_Start`
`Shader_Start` (`libphx/src/Shader.cpp:238-248`) pulls every registered autovar from the
`ShaderVar` stack and calls `glUniform*` **at shader-start time**, not per draw. Any pass
that starts a shader *before* pushing its render-target viewport bakes in whatever was on
top of the stack — usually the window's matrices.

- **Symptom:** skybox "empty squares"/gaps at 150 that didn't exist at 140. Pixel dump of
  the generated cubemap showed every face only ~64% covered (left filled, right black):
  the face quad (pixels 0..1024) was transformed by the WINDOW ortho (1600 wide), reaching
  NDC ≈ +0.28 instead of +1.
- **Root cause:** `TexCube_Generate` called `ShaderState_Start(state)` before
  `RenderTarget_Push(size, size)`; `mProjUI/mViewUI` were uploaded with window values.
  Harmless at ≤140 because `ui.glsl` still read fixed-function matrices that
  `Viewport_Set` reloaded per push; fatal once ui.glsl moved to autovars.
- **Fix:** start the shader *inside* the first RT push:
  `RenderTarget_Push(...)` → `if (i == 0) ShaderState_Start(state)` → draw → `Pop`
  (`libphx/src/TexCube.cpp:214-260`). Per-face Push/Pop must stay (fresh FBO per cube
  face; one outer Push overflows color attachments: `Max color attachments exceeded`).
- **Rule for future passes:** if a pass draws through `ui`/`ui3D` (anything consuming
  `mProjUI`/`mViewUI`) into an offscreen target, Start the shader after the Push. Passes
  using matrix-free vertices (`identity.glsl` passes position straight to clip space) are
  immune — that's why `TexCube_GenIRMap.cpp:68` is safe.

### Finding 2: Mesa rejects `gl_ProjectionMatrix` at `#version 150` despite COMPAT context
Even with `SDL_GL_CONTEXT_PROFILE_COMPATIBILITY`, shaders declaring bare `#version 150`
fail with `'gl_ProjectionMatrix' undeclared` (spec-correct: no profile token = core). Two
part answers: (a) migrate such shaders off fixed-function builtins (done for
`ui.glsl`/`ui3D.glsl` via `Viewport_Push`/`Viewport_Pop` pushing `mProjUI`/`mViewUI`,
`res/shader/include/vertex.glsl` declares them); (b) emit `"#version NNN compatibility\n"`
from stage 3 onward as belt-and-braces until the CORE flip.

### Stage 3 debug tooling (kept, env-gated, in `libphx/src/TexCube.cpp`)
- `PHX_DEBUG_TEXCUBE=1` — bypass the adaptive band tiler, one unscissored full-face draw.
- `PHX_DEBUG_TEXCUBE_DUMP=<prefix>` — dump all 6 generated faces (level 0) to PNGs via
  `glGetTexImage`. This is what proved the faces themselves were partially covered and
  ended the guessing game.
- Debug chain that isolated it (reuse this order): direct-gradient skybox (geometry OK)
  → sample envMap (content broken) → tiler bypass (not the tiler) → min-filter Linear
  (not mips) → pixel dump (found coverage hole) → reorder fix.

### Hardening applied during stage 3
- `starbg.glsl`: `if (a < 0.02) discard;` — star quads span ~4°; without it their
  near-black margins overwrite the G-buffer albedo painted by the skybox.
- `MasterControl.lua`: nil guards on `playerShip:getParent():hasDockable()`.
- All legacy texture fns migrated (`texture1D/2D/3D/Cube` → `texture()`/`textureLod()`).

### Known issues NOT caused by the upgrade (observed during 5-run QA)
- `BSP Incoming Mesh Error: Vertex Position Underflow` — pre-existing, seed-dependent
  degenerate asteroid mesh (`libphx/src/Triangle.cpp:84`).
- `GameView.lua:21 attempt to call method 'beginRender' (a nil value)` — Lua-side dangling
  reference, likely same deleted-entity family as MasterControl; investigate separately.

### What makes each trouble spot a trouble spot

- **3.3 / GLSL 330:** the core profile drops every deprecated fixed-function built-in. With B/C/D/E already done in stage 3, the remaining work is checklist A: convert the ~73 `gl_FragColor` fragment shaders to explicit `out vec4`. Vertex side is clean (`gl_Vertex` gone since stage 3, `mProjUI/mViewUI` in place — mind the eager-autovar trap).
- **4.0 / GLSL 400:** last of the legacy removals land; safe to flip the context to CORE profile, which removes immediate mode from the driver entirely. C++ must be 100% on the VBO path (it is — `Draw.cpp` was already rewritten).
- **4.3 / GLSL 430:** compute shaders and SSBOs become real. The engine's legacy "compute" fragment passes (`computeAO`, etc.) can be migrated to native `.comp` + `glDispatchCompute`, or left as-is (they still compile).
- **4.6 / GLSL 460:** final gate — SPIR-V support, robust buffer access. No forced shader syntax changes, but this is where the full deprecation sweep and GLEW capability verification happen.

## Shader Migration Checklist (for Stage 4)

Counts verified 2026-08-22 after stage 3: **73** fragment files still use `gl_FragColor`
(only remaining legacy output; `gl_FragData[]` = 0, `varying`/`attribute` = 0,
`texture1D/2D/3D/Cube` = 0, `gl_ProjectionMatrix`/`gl_ModelViewMatrix` = 0).

### A. Fragment outputs (`gl_FragColor` → `out vec4`) — REMAINING (the only real stage-4 work)
Each of the ~73 fragment shaders needs `layout(location=0) out vec4 outColor;` +
`gl_FragColor→outColor` (deferred G-buffer files already use `fragData0/1/2` via
`res/shader/include/deferred.glsl` — add `layout(location=0/1/2)` for `330`, with
`libphx/src/Shader.cpp:98-101` `glBindFragDataLocation` fallback).
- UI/filter/effect/compute: `layout(location=0) out vec4 outColor;`
- Deferred: verify `material/*` and `light/*` keep using `setAlbedo()` etc.

### B. Texture functions — DONE during stage 3
All `texture2D/texture1D/texture3D/textureCube/textureCubeLod` calls migrated to
`texture()`/`textureLod()` across both shader trees. Zero remain.

### C. Vertex shaders — DONE during stage 3
`ui.glsl`/`ui3D.glsl` migrated off `gl_ProjectionMatrix/gl_ModelViewMatrix` onto
`mProjUI/mViewUI` autovars pushed by `Viewport_Push`/`Viewport_Pop`
(`libphx/src/Viewport.cpp`). `farplane.glsl` already used `mView/mProj`. Remember the
eager-autovar trap from the Stage 3 notes when adding passes that consume them.

### D. Immediate mode — DONE
`libphx/src/Draw.cpp` VBO done. `starbg` discard guard added (`if (a < 0.02) discard;`).

### E. Lua — DONE
`MasterControl.lua` nil guards re-applied on `playerShip/getParent/hasDockable`.

## Per-Stage Procedure

For **every** stage (1–11):

1. Branch: `git checkout -b upgrade-gl<MAJOR>_<MINOR>`
2. Edit the two values together — context and shader version must move in sync:
   - `src/Main.cpp:15` → `Engine_Init(<M>, <m>);`
   - `libphx/src/Shader.cpp:27` → `versionString = "#version <NNN> compatibility\n";`
     (from stage 3 on, keep the `compatibility` token until the stage-5 CORE flip)
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
- **Skybox missing squares / boxes moving when flying / stars through skybox** → two distinct causes, check in this order:
  1. **Stale `mProjUI/mViewUI`** (stage 3 root cause): shader started before its render-target viewport was pushed → face quads transformed by window ortho → every cubemap face partially covered (pixel-dump with `PHX_DEBUG_TEXCUBE_DUMP` shows a clean straight-edge hole). Fix: `ShaderState_Start` inside the first `RenderTarget_Push` (`libphx/src/TexCube.cpp:214-260`).
  2. `farplane.glsl:22` `z=w` clips half `Box3(-1,1)` faces behind the camera (`w<0`) at core GLSL — boxes moving when flying. `skybox.glsl:11` `texture(envMap,V)` + `starbg` without `discard a<0.02` → near-black star-quad squares over the skybox.
- **GLSL compile error `unexpected ')' or end of file` right after editing a comment** → a `*/` sequence inside a block comment closes it early (e.g. writing `lut*/starDir` in prose). Keep `*` and `/` apart in shader comments.
- **`BSP Incoming Mesh Error: Vertex Position Underflow`** → pre-existing, seed-dependent degenerate asteroid mesh (`Triangle.cpp:84` `edgeLen<0.75*PLANE_THICKNESS_EPSILON`, e.g. seeds `841200697710436919ULL` / `16480941435429704151ULL`). Not GL-related; harmless warning unless it aborts.
- **`GameView.lua:21 attempt to call method 'beginRender' (a nil value)`** → Lua-side dangling `world` reference (deleted-entity family as `MasterControl`). Not GL-related; caught by xpcall.
- **Context creation returns NULL / engine aborts at boot** → driver refused the requested version/profile; check `SDL_GL_GetError()` output and Mesa DRI version.
- **Rollback:** revert the two-line change (`Main.cpp` + `Shader.cpp`) plus any profile-mask flip, rebuild, re-run. Each stage is independent — a failed stage rolls back to the previous green commit without touching earlier stages.

#### Affected Shader Files
- Fragment shader files containing legacy `gl_FragColor` output: ~73 files under `res/shader/fragment/**`. Run `rg -l 'gl_FragColor'` to list them; each needs an explicit `out vec4 outColor;` declaration and replacement of the `gl_FragColor` assignments.
- Texture function files using legacy texture calls: ~38 files. Use `rg -l 'texture2D('` and similar patterns to identify them; replace with `texture(...)`, `textureLod(...)`, or `textureCube...`.
+ *Add a tip:* If you hit a green‑screen after bumping to 4.0, first run the `glBegin` test path in `Draw.cpp` (should be dead code) – sometimes drivers still expect it for internal state.
