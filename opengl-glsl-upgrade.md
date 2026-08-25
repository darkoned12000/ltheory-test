# OpenGL / GLSL Upgrade Plan (Full Version Ladder)

Goal: migrate the engine from its current state up to **OpenGL 4.6 / GLSL 460**, one version at a time, keeping the GL context and the shader `#version` in sync at every step. Each stage is tested before moving on. Trouble spots (structural changes that force C++ or shader rewrites) are flagged — they land at **3.3, 4.0, 4.3, and 4.6**.

## Current State (verified 2026-08-22 — LADDER COMPLETE at 4.6/460 CORE)

| Item | Value | Location |
|---|---|---|
| Context requested | OpenGL **4.6 core** | `src/Main.cpp:15` — `Engine_Init(4, 6)` |
| Shader version | GLSL **460 core** (GL 4.6) | `libphx/src/Shader.cpp:27` — `versionString = "#version 460 core\n"` |
| Profile mask | `SDL_GL_CONTEXT_PROFILE_CORE` | `libphx/src/Engine.cpp:74-81` |
| Driver capability | Mesa 26.2 → **GL 4.6** granted | system ICD |
| GLEW | 2.2.0; `glewIsSupported("GL_VERSION_4_6")` printed at boot in the `[GL]` banner | system `libglew-dev` |

**The full version ladder is COMPLETE (stages 0–11 GREEN, final gate passed 2026-08-22).**
One global VAO is created and bound
forever in `OpenGL_Init` (`libphx/src/OpenGL.cpp`) — core profile has **no default VAO**,
so every draw depends on it. All immediate-mode rendering is gone: `Draw.cpp` exposes an
internal `Imm_*` API (`DrawInternal.h`) used by `Tex1D`/`Tex2D`/`Mesh_DrawNormals`; dead
`Tex3D_Draw` was deleted. `GLMatrix.cpp` is a pure-CPU matrix stack (numerically proven
equivalent to the old fixed-function pipeline).

**Legacy-token status after stage 5 — all ZERO across `res/shader/` AND C++:**
`gl_FragColor`/`gl_FragData[]`, `varying`/`attribute`, legacy texture fns,
embedded `#version`, `glBegin/glEnd/glVertex*`, fixed-function matrix calls.
Validate shader changes offline with `python3.13 tools/validate_glsl.py <NNN>`
(python3.13 specifically: moderngl lives under its site-packages on this host).

## Version Ladder (check off as each stage lands)

GLSL versions map to OpenGL versions: 130→3.0, 140→3.1, 150→3.2, 330→3.3, 400→4.0, 410→4.1, 420→4.2, 430→4.3, 440→4.4, 450→4.5, 460→4.6.

| # | Stage | GL context (`Engine_Init`) | GLSL `#version` | Structural trouble? | C++ work required | Shader work required | Status |
|---|-------|---------------------------|-----------------|---------------------|-------------------|----------------------|--------|
| 0 | Baseline (today) | `(2, 1)` compat | `130` | — | none | none | done |
| 1 | **3.0** | `(3, 0)` compat | `130` (unchanged) | No — low risk | none (context only) | none | done (via 3.1 bump) |
| 2 | **3.1** | `(3, 1)` compat | `140` | No — low risk | optional: UBOs become available | optional: adopt uniform buffers | done |
| 3 | **3.2** | `(3, 2)` compat | `150 compat` | **YES**: `gl_ProjectionMatrix` rejected at 150 forced the `ui`/`ui3D` migration + `Viewport` `mProjUI/mViewUI`; TexCube autovar-order fix | done: ui/ui3D modernization, legacy texture fns → `texture()`, starbg discard, MasterControl guards, TexCube reorder | see Stage 3 notes | done |
| 4 | **3.3** ⚠️ | `(3, 3)` compat* | `330 compatibility` | **YES — core-language cutover**, plus latent-bug sweep (see Stage 4 notes) | keep COMPAT mask until C++ is clean; later flip to CORE. Built clean first try | checklist A: 73 fragment files → `layout(location=0) out vec4 fragColor;` (146/148 call sites); BRUSH_OUTPUT macro blind spot fixed; 12 pre-existing broken shaders repaired | done — 113/113 offline at 330 core + runtime QA green |
| 5 | **4.0** ⚠️ | `(4, 0)` core | `400` | **YES — last legacy removals** | done: CORE flip + global VAO (`OpenGL_Init`), `Imm_*` VBO API in `Draw.cpp` (Tex1D/Tex2D/Mesh_DrawNormals converted, Tex3D_Draw deleted), CPU matrix stacks (`GLMatrix.cpp`), passthrough blit shaders | subroutines available; no shader changes needed | done — see Stage 5 notes (black-screen root cause) |
| 6 | **4.1** | `(4, 1)` core | `410` | No — low risk | none required (two-line bump) | optional: explicit uniform locations, textureGather — NOT adopted yet | done |
| 7 | **4.2** | `(4, 2)` core | `420` | No — but exposed a validator bug (see Stage 7 notes) | none required (two-line bump) | optional: image load/store, dual-source blending — not adopted | done |
| 8 | **4.3** ⚠️ | `(4, 3)` core | `430` | Only if ADOPTING compute — bump itself is additive | none required; `.comp` plumbing deferred until a feature justifies it | optional (NOT done): migrate Mesh_ComputeAO to native `.comp` + SSBOs — see Stage 8 notes | done |
| 9 | **4.4** | `(4, 4)` core | `440` | No — low risk | none required | optional: sparse texture access, non-uniform derivatives | done |
| 10 | **4.5** | `(4, 5)` core | `450` | No — low risk | none required | optional: transform-feedback qualifiers, I/O interning | done |
| 11 | **4.6** ⚠️ | `(4, 6)` core | `460` | **YES — final gate** | done: GLEW capability flag in `[GL]` banner (`glewIsSupported("GL_VERSION_4_6")`) | done: final deprecation sweep — ZERO legacy tokens; only doc comments mention removed APIs | LADDER COMPLETE (stages 9–11 landed together) |

\* Stage 4 keeps the COMPATIBILITY mask on purpose: it lets us bump GLSL to 330 (core-profile language) while any straggler C++ calls still work, then flip to CORE at stage 5 once everything is verified.

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

### Known issues NOT caused by the upgrade (observed during QA)
- `BSP Incoming Mesh Error: Vertex Position Underflow` — pre-existing, seed-dependent
  degenerate asteroid mesh (`libphx/src/Triangle.cpp:84`).
- `GameView.lua:21 attempt to call method 'beginRender' (a nil value)` — Lua-side dangling
  reference, likely same deleted-entity family as MasterControl; investigate separately.

## Stage 4 (3.3 / 330) Notes — DONE 2026-08-22

The mechanical part went fast; the value was in what the offline validator caught.

### Conversion mechanics
- All 73 `gl_FragColor` fragment shaders → explicit `layout(location = 0) out vec4 fragColor;`
  declared before the first code line, refs rewritten (`fragColor`, not `outColor` — keep
  ONE canonical name). 146 files / 148 call sites across both shader trees.
- **Macro blind spot:** grep-based scans miss macro-mediated output. `brush.glsl` defines
  `BRUSH_OUTPUT(x)` expanding to a write of the old builtin — 9 brush shaders never matched
  any `gl_FragColor` grep yet still needed the output declared. Fix: declare the output
  *inside* the include so every includer gets it. Lesson: when auditing shader-wide changes,
  also grep `#define`s for legacy tokens.
- `deferred.glsl` `fragData0/1/2` left WITHOUT explicit locations: linker assigns 0/1/2 in
  declaration order and runtime QA is green. Optional hardening before/at stage 5: add
  `layout(location=0/1/2)` explicitly.

### Latent bugs found & fixed (all pre-existing, none caused by the upgrade)
These compiled under NOTHING — they are unused-at-runtime leftovers that would have kept
rotting. The validator found them on the first pass:

| File(s) | Bug | Fix |
|---|---|---|
| `filter/identity`, `simple_color`, `simple_image`, `ui/circle-old`, `ui/ringdim`, `gen/nebula4_weak` | wrote undeclared `outColor` (illegal under every GLSL version) | added `layout(location=0) out vec4 outColor;` |
| `material/uv_metal` | unbalanced parens (missing `)`) — syntax error since inception | fixed |
| `material/triplanar` | duplicate `eye` + `envMap` uniforms vs `fragment.glsl` (compat-profile leniency only) | removed dups |
| `brush/desat` | used `saturate()` without `#include math` | include added |
| `ptracer` | embedded `#version 450`, undefined `SCENE_DESC` placeholder (`#if 1` selected it!), pre-420pack aggregate initializers, undeclared `boxes` array | dropped embedded version, `#if 1→0`, `#extension GL_ARB_shading_language_420pack`, stub array |
| `common.glsl` | dead `GL_EXT_gpu_shader4` extension + ifdef (HIGHQ was force-defined anyway) | removed; `#define HIGHQ` unconditional |

Duplicate-uniform redeclaration compiles on Mesa compat but REJECTS on core/EGL — another
reason the offline validator runs at CORE (see below): it simulates the strictest future state.

### Offline validation harness (new tooling)
`tools/validate_glsl.py` — compiles AND links every vertex/fragment shader headlessly via a
standalone moderngl/EGL context:

```bash
python3 tools/validate_glsl.py [NNN]   # explicit version
python3 configure.py test              # auto-detects NNN from libphx/src/Shader.cpp
```

- Replicates the engine preprocessor: recursive `#include` resolution + `#autovar` strip,
  then prepends `#version` exactly like `Shader.cpp`. Auto-detect means bump `Shader.cpp`
  once and the harness follows — no drift between engine level and test level.
- **EGL cannot create compatibility profiles** (GLX can — that's why the game runs fine).
  So the harness validates at `<NNN> core`: stricter than runtime compat, and from stage 4
  the tree has zero compat-only builtins, making core validation legal everywhere.
- Each file links against an auto-generated **stub counterpart** built from its own
  interface declarations (fragment's `in`s → stub VS outs, vertex's `out`s → stub FS ins),
  giving every file true driver-side compile+link coverage without knowing real pairs.
- Stage-4 result: **113/113 OK at 330 core**, then runtime QA green (skybox/stars/sun/
  flight/weapons/thrusters).
- Future tier (proposed): extend with real-pair linking by scraping `Cache.Shader(vs, fs)`
  calls, then semantic unit tests (render pure-function shaders — `filter/*`, `ui/*` SDFs —
  into small FBOs and assert pixel outputs); golden-image regression only with tolerance-
  aware diffing. Headless EGL makes tiers 1–2 CI-able (llvmpipe).

## Stage 5 (4.0 / 400 CORE) Notes — DONE 2026-08-22

The profile flip was two lines; making it *work* took a full debugging campaign. Findings
in order of importance for future work:

### Finding A: core profile has NO default VAO
In compatibility profiles VAO 0 exists implicitly and records attrib state; in core it
does not exist at all — `glVertexAttribPointer` and draws silently do nothing. Fix: one
global VAO, created right after `glewInit()` in `OpenGL_Init` and never unbound. All
`Draw_Bind`/`Mesh_DrawBind` attrib state lands in it, exactly mirroring old VAO-0
semantics with zero call-site changes.

### Finding B: `glUseProgram(0)` blits are silent no-ops under core (Mesa)
`Shader_Stop` calls `glUseProgram(0)`. Any draw issued afterward relied on the
compatibility-profile **fixed-function fallback** for program 0. Under core that fallback
is gone — and **Mesa radeonsi does NOT raise `GL_INVALID_OPERATION`**; it rasterizes
nothing, silently. This is why `ENABLE_GLCHECK=1` reported zero errors on a fully black
screen. Rule: **every draw must have an explicitly started program** — no residual-program
blits. Fixed sites (`script/phx/util/Renderer.lua`): `present()`, `presentAll()`, and the
supersample downsample in `startPostEffects()` now wrap their quads in
`Cache.Shader('ui','filter/identity')` start/stop.

### Finding C: how the black screen was diagnosed (reuse this playbook)
1. `ENABLE_GLCHECK 1` (`libphx/include/PhxConfig.h`) + `[GL]` context banner print in
   `OpenGL_Init` → proved context was 4.x CORE and zero GL errors fired.
2. Env-gated PNG dumps added to `GameView.lua` (`PHX_DEBUG_DUMP=<frame>`): gbuffer albedo,
   normal/mat, zBufferL after opaque pass, final buffer before present. Result: pipeline
   content was FINE all the way to the final buffer → failure isolated to window present.
3. Red-clear probe in `Window_EndDraw` → red window → swap chain fine → only the present
   blit itself broken → Finding B.
   (Probe removed post-diagnosis; dumps kept as documented tooling.)

### Other stage-5 changes
- `Draw.cpp`: internal `ImmVert {x,y,z,u,v}` + `Imm_Bind/Imm_Unbind/Imm_Draw`
  (`DrawInternal.h`); `Draw_Expand` converts GL_QUADS/GL_POLYGON → triangles pre-draw.
  `Tex1D/Tex2D` draws and `Mesh_DrawNormals` converted; `Tex3D_Draw` deleted (dead code,
  needed vec3 texcoords we don't carry) along with its Lua FFI bindings.
- `GLMatrix.cpp`: pure-CPU P/WV stacks replacing fixed-function matrix state; proven
  equivalent to the old GL path via offline simulation (3000 random op sequences,
  0 divergences). Lua consumers: `GameView` UI pass, dev apps.
- `Viewport_Set` reduced to `glViewport` only; legacy matrix-mode calls removed from
  `OpenGL_Init`; `glLineWidth(2)` dropped (widths >1 are core-illegal anyway).

## Stage 6 (4.1 / 410) Notes — DONE 2026-08-22

Two-line bump (`Engine_Init(4,1)` + `#version 410 core`). Validator green, runtime QA
green ×3. Optional features (explicit uniform locations, `textureGather`) NOT adopted —
planned as a separate optimization branch starting with the blur filter family.

## Stage 8 (4.3 / 430) Notes — DONE 2026-08-22

Two-line bump; validator green; QA clean. Compute/SSBO adoption deliberately DEFERRED:

- The engine's only "compute" pass is `Mesh_ComputeAO` (`libphx/src/Mesh_ComputeAO.cpp`),
  which bakes per-vertex AO into unused `uv.x` at mesh-generation time via the classic
  render-to-texture GPGPU trick + `fragment/compute/occlusion.glsl`. It runs at world-gen,
  not per frame — no runtime pressure to migrate.
- Real compute needs engine plumbing first: `Shader_Load` only handles vertex/fragment
  pairs, so `.comp` support (stage enum, dispatch API, SSBO/buffer management) is a
  feature project. Adopt alongside the first feature that needs it (GPU particles is the
  leading candidate), not for its own sake.
- textureGather/half-tap note: the opt branch (merged 2026-08-22) proved gather does NOT
  fit this codebase's RGBA blur chain; half-tap bilinear merging landed instead
  (`filter/blur.glsl`, ~2x fewer fetches). Gather stays relevant for future single-channel
  passes (shadow-map PCF, depth-aware effects).

## Stage 7 (4.2 / 420) Notes — DONE 2026-08-22

Two-line bump exposed a **latent bug in the offline validator**: stub counterpart shaders
declared interface variables with a `v_` name prefix (`out vec3 v_vertPos`) that NEVER
matched the real fragment inputs (`vertPos`). Mesa ≤4.10 linked these mismatches anyway
(leniency), so prior "113 OK" results had weaker link coverage than believed; 420's
stricter interface matching rejected them (98 FAILs). Fixed: stub names now equal the
interface names exactly. Post-fix genuine result: **113/113 at both 410 and 420**, then
runtime QA green. Lesson: interface-matching bugs hide behind driver leniency — trust the
validator only when its stubs are provably symmetric.


### What makes each trouble spot a trouble spot

- **4.0 / GLSL 400:** last of the legacy removals land; safe to flip the context to CORE profile, which removes immediate mode from the driver entirely. C++ must be 100% on the VBO path (it is — `Draw.cpp` was already rewritten).
- **4.3 / GLSL 430:** compute shaders and SSBOs become real. The engine's legacy "compute" fragment passes (`computeAO`, etc.) can be migrated to native `.comp` + `glDispatchCompute`, or left as-is (they still compile).
- **4.6 / GLSL 460:** final gate — SPIR-V support, robust buffer access. No forced shader syntax changes, but this is where the full deprecation sweep and GLEW capability verification happen.

## Shader Migration Checklist — COMPLETE after stage 4

Final counts verified 2026-08-22: `gl_FragColor`/`gl_FragData[]` = 0,
`varying`/`attribute` = 0, legacy texture fns = 0,
`gl_ProjectionMatrix`/`gl_ModelViewMatrix` = 0, embedded `#version` = 0.

### A. Fragment outputs (`gl_FragColor` → `out vec4`) — DONE during stage 4
All 73 fragment files converted to explicit `layout(location = 0) out vec4 fragColor;`
(canonical name: `fragColor`; the six pre-existing `outColor` users keep their local
declaration). Deferred G-buffer files use `fragData0/1/2` via
`res/shader/include/deferred.glsl` (linker-assigned locations 0/1/2; optional explicit
`layout()` hardening noted in Stage 4 notes).

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
   - `libphx/src/Shader.cpp:27` → `versionString = "#version <NNN> core\n";`
     (stages 3–4 used the `compatibility` token; from stage 5 CORE flip onward it's `core`)
3. At stage 4 only: complete the Shader Migration Checklist **before** flipping `#version`.
4. At stage 5 only: flip `SDL_GL_CONTEXT_PROFILE_MASK` to `SDL_GL_CONTEXT_PROFILE_CORE` in `libphx/src/Engine.cpp` (after confirming zero legacy C++ GL calls remain).
5. Rebuild and run:
   ```bash
   python3 configure.py build && ./run.sh LTheory
   ```
6. Validate shaders offline BEFORE running (catches ~all compile failures in seconds):
   ```bash
   python3 configure.py test        # runs tools/validate_glsl.py at the engine's GLSL level
   ```
   Then rebuild and run, still watching stderr for `CreateGLShader: Failed to compile shader`
   (runtime catches real-pair link issues the stub validator cannot see).
7. Visual QA sweep: skybox, stars, G-buffer materials, UI/HUD, post-processing filters, effects. Confirm no missing/broken passes.
8. Commit on green. Check off the stage in the table above and update `AGENTS.md`.

## Known Failure Modes & Rollback

- **`'gl_FragColor' undeclared` / `'gl_Vertex' undeclared` / legacy texture fn errors** at first shader compile → a shader still uses legacy syntax removed by the new GLSL version. Since stage 4 the tree is fully clean — if `python3 configure.py test` passes but runtime still fails, suspect a real vs/fs pair link mismatch or an include not present in BOTH trees (`res/shader/` and `res/ltheory-test-master/res/shader/`; note the master tree is a partial copy and lacks some files).
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

#### Affected Shader Files — HISTORICAL, all resolved as of stage 4
The legacy-token audit (`gl_FragColor` outputs, legacy texture fns) is complete — see
"Shader Migration Checklist" above. For any future audit, run
`python3 tools/validate_glsl.py <NNN>` instead of grepping: it catches undeclared
identifiers, syntax errors, duplicate uniforms, and macro-mediated output writes that
greps miss. Remember to check `#define` bodies for hidden legacy tokens (the
`BRUSH_OUTPUT` lesson from Stage 4).

## Stage 9–11 Notes (4.4/440 → 4.5/450 → 4.6/460) — LADDER COMPLETE

All three remaining stages landed together on branch `upgrade-gl4_6` (2026-08-22),
validated at every intermediate level before moving on:

| Level | Validator | Notes |
|---|---|---|
| 440 | 113/113 | additive; nothing adopted |
| 450 | 113/113 | additive; nothing adopted |
| 460 | 113/113 | final gate — see below |

- **Process:** context and `#version` bumped in lockstep per level
  (`Main.cpp:15` / `Shader.cpp:27`); validator run after each GLSL bump;
  single rebuild + one QA cycle at the final state (`Engine_Init(4, 6)`).
  QA result: clean, no graphic anomalies.
- **Near-miss worth recording:** the first scripted bump left the *context* at
  `(4, 4)` while shaders reached `460` — the loop iterated `Shader.cpp` only.
  Requesting a 4.6-core context with a mismatched context would break at window
  creation or silently change driver behavior. **Always grep both lines after any
  scripted version edit** (`grep -n Engine_Init src/Main.cpp && grep -n versionString libphx/src/Shader.cpp`).
- **Final deprecation sweep (gate requirement):** zero legacy tokens across all
  shaders AND C++. The only grep hits are doc comments in `Draw.cpp:10` and
  `Tex3D.cpp:76` describing what was removed in stage 5 — no live calls.
- **GLEW capability verification (gate requirement):** the `[GL]` boot banner now
  prints `glew-4.6 yes/no` via `glewIsSupported("GL_VERSION_4_6")`
  (`libphx/src/OpenGL.cpp`). A granted context alone doesn't prove GLEW resolved
  the entry points; this makes it visible on every boot.
- **Optional features deliberately NOT adopted** (all remain callable at 4.6):
  sparse textures, non-uniform derivatives (4.4), transform-feedback qualifiers (4.5),
  SPIR-V loading (4.6), plus the older deferrals (explicit uniform locations,
  textureGather, image load/store). Each is tracked in AGENTS.md's
  "Post-4.6 Modernization Backlog" with its trigger condition — adopt when the
  corresponding feature work starts, never speculatively.

## Runtime Hardening — Post-4.6 (2026-08-25)

The ladder makes shaders *portable across versions*; this work makes them *safe at runtime*
and the engine *runnable on weak + strong hardware*. Ordered by value-to-risk, all additive:

### 1. Offline validator restored + runnable headlessly (DONE)
`python3 configure.py test` was failing with `ModuleNotFoundError: No module named 'moderngl'`.
Cause: moderngl is **not** a system package on this host; AGENTS.md's ladder notes assume it
is already present ("use python3.13 — moderngl lives under its site-packages"). It isn't, so
the pre-flight gate was effectively dead.

- **Fix:** `python3.13 -m pip install --break-system-packages moderngl pytest`. Now the validator
  runs headlessly via llvmpipe/EGL at the engine's GLSL level:
  ```bash
  python3.13 configure.py test        # 118 OK, 0 FAIL at 460 core (verified)
  ```
- **Why it matters:** this is the single most important hardening step for "not prone to small
  syntax failures during runtime." A typo in a `.glsl` now fails at configure time, not mid-game.
- **Caveat:** `configure.py` uses `sys.executable`, so *always* invoke it as `python3.13`. Using
  the system `python3` (3.14 here) both blocks pip and can't run moderngl's headless backend.

### 2. GPU particle emitters — validated feature work, ready to commit (DONE / not yet committed)
The working tree carried a full "GPU particle explosions" implementation that replaces the
legacy CPU `Explosion` billboards:
- `Explodable.lua`: one scale-boosted `GPUParticles.explode(...)` burst instead of 8 billboards.
- `Asteroid.lua`: destruction debris now emits from the GPU pool (dropped the 6-board billboard loop).
- `ShipType.lua`: thruster mount search flipped to **+Z hull rear** (`Vec3f(0,0,1)`) — ships fly
  along −Z, so mounting on −Z normals was firing plumes straight through the nose. This is the
  *actual* root cause of the "tail looks like a wall/glass / crawls up" symptom: thrusters were
  placed on the wrong side of the hull.
- `GameView.lua`: death-guard so the post-view skips drawing when the player's world was swept
  from the system (no nil `beginRender` crash).
- Compute kernels (`particle_spawn`/`particle_simulate`) + `gpu_particle.glsl` got a streak-shaping
  exhaust-vector field.

**Validated:** `python3.13 configure.py test` → **118 OK, 0 FAIL at 460 core**, including the modified
`gpu_particle.glsl`. Cleaned up my throwaway capture harness (`script/App/CaptureThruster.lua`,
`cap_*.png`) before this — do not commit screenshots.

### 3. Build-time validation gate (PENDING)
`configure.py test` works but is run *manually* per the ladder procedure (§ "Per-Stage Procedure").
To make it a hard pre-flight step, wire it into `CMakeLists.txt` / `configure.py` so a build fails if
any shader won't compile+link offline. Zero runtime cost; eliminates the last path to an in-game
shader crash that the validator doesn't cover (real vs/fs pair link mismatches — see § "Known Failure
Modes").

### 4. Graceful runtime shader failure (PENDING)
Currently a bad `#version`/typo at first draw → `Fatal()` / abort with no context. Design: log the
exact failing stage + source, fall back to a cached-good program if one exists, else show an in-game
overlay ("shader X failed to compile"). This is what turns "black screen mid-flight" into recoverable.

### 5. GPU-quality settings panel (PENDING — biggest portability win)
No options menu exists; quality is fixed at max → modern machines run fine but old ones stall. Design:
a `Config.gpu` block (`maxParticles`, `computeShadows`, `bloom`, `superSample`) with a runtime toggle,
so the same binary scales from integrated GPU to RTX. This directly serves "perform well on older and
newer machines."

### GLEW vs GLAD (advisory)
Keep **GLEW 2.2.0** for now — it works and exposes every extension through 4.6; switching mid-project
is churn. If you optimize for the "fail fast, not silently" goal, **GLAD** is worth a future pass:
regenerating the loader pins *exactly* which version/profile gets loaded (e.g. `4.6 core`), so a typo'd
function name or accidental legacy call fails at generation time rather than on some random driver at
runtime. The inverse risk it adds — forgetting to regenerate after adding an extension — is manageable
with the build-time gate (§3). **Not needed for the current hardening pass.**

### Next milestone: Post-4.6 backlog, led by compute plumbing (`.comp` stage) and GPU particles.
