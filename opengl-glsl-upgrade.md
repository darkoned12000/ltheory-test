# OpenGL / GLSL Upgrade Plan (Full Version Ladder)

Goal: migrate the engine from its baseline up to **OpenGL 4.6 / GLSL 460**, one version at a time, keeping the GL context and shader `#version` in sync at every step. Each stage is validated before moving on. Structural trouble spots land at **3.2, 4.0, 4.3, 4.6**.

## Status (verified 2026-08-22 — LADDER COMPLETE)
- Context: `Engine_Init(4, 6)` → **GL 4.6 core** (`src/Main.cpp:15`, `libphx/src/Engine.cpp`)
- Shader: GLSL **460 core** at `libphx/src/Shader.cpp:27`
- GLEW 2.2.0 prints a `[GL] ... glew-4.6 yes/no` capability flag on boot (`OpenGL.cpp`). Mesa grants 4.6, GLEW exposes every extension through it — no upgrade needed.
- One global VAO bound for the process lifetime (core profile has none) in `OpenGL_Init`.
- Zero legacy tokens across shaders AND C++: `gl_FragColor`/`gl_FragData`, `varying`/`attribute`, legacy texture fns, embedded `#version`, `glBegin/glEnd`, fixed-function matrix calls. Only doc comments mention removed APIs.

**All 12 ladder stages (0–11) are done.** The only remaining work is the **Pre-Main Checklist** below — feature investments, not correctness fixes; do them before merging to main.

## Version Ladder
GLSL↔GL: 130→3.0 … 460→4.6.

| Stage | GL context | GLSL | Trouble? | Status |
|---|---|---|---|---|
| 0 | (2,1) compat | 130 | — | done |
| 1–2 | ≤(3,1) compat | 130→140 | low risk | done |
| 3 | (3,2) compat | 150 **compat** | core-language cutover + latent sweep | done |
| 4 | (3,3) compat* | 330 | 73 frag files → explicit outputs; validator repairs | done |
| 5 | (4,0) **core** | 400 | CORE flip + global VAO + `Imm_*` VBO draw path | done |
| 6–10 | (4,1)→(4,5) core | 410→450 | additive two-line bumps; nothing adopted yet | done |
| 11 | (4,6) **core** | 460 | final gate — deprecation sweep + GLEW flag | done |

\* Stage 4 holds the compatibility mask on purpose: it lets GLSL reach core-language 330 while straggler C++ calls still work; flip to CORE at stage 5.

## Two findings that apply to every later stage (read first)
1. **`#autovar` uniforms upload once, eagerly, at `Shader_Start`.** Any pass that starts its shader *before* pushing its render-target viewport bakes in the window matrices on top of the stack. Fix: start the shader inside the first RT push (`RenderTarget_Push → if (i==0) ShaderState_Start(state)`). Passes using matrix-free vertices (`identity.glsl`) are immune.
2. **Mesa core rasterizes nothing under `glUseProgram(0)`, silently** — no `GL_INVALID_OPERATION`. Rule: **every draw must run under an explicitly started program.** Fixed sites in `Renderer.lua`: `present()`, `presentAll()`, supersample downsample.

## Offline validator (the safety net for shader edits)
`python3.13 configure.py test` → `tools/validate_glsl.py`, compiles+links every vs/fs headlessly via moderngl/EGL at the engine's GLSL level and auto-parsed from `Shader.cpp`. EGL can't make compat profiles, so it validates at `<NNN> core` (stricter than runtime). Stage-5 result: **113/113 OK**. Always run before any `.glsl` edit — a typo now fails at configure time.

## Post-4.6 hardening (all done)
- **Validator restored** (`moderngl pytest` installed; `configure.py test` was dead). Invoke as `python3.13` — `configure.py` uses `sys.executable`.
- **Graceful runtime shader failure** (`74f717a`): C++ non-abort + cached-good program fallback + in-game overlay naming the bad pass. A broken shader degrades instead of crashing.
- **GPU-quality settings panel** (`Config.gpu`, Renderer seeds bloom/sharpen from it at startup) — weak hardware drops expensive post-passes instead of shipping broken. Visually testable via the planet's atmosphere rim glow.
- **Planet spawn**: `System:spawnPlanet()` returns its handle; app pushes the ship clear of the surface if too close (bearing preserved).

## Pre-Main Checklist (do these before merging to MAIN)
Ordered by expected impact. All currently **NOT started**. Engine runs fully functional now — these are feature investments, not correctness fixes.

1. **Point-light shadow maps** — deferred light passes (`light/global.glsl`, `light/point.glsl`) do unshadowed radial falloff. Shadow depth maps make textureGather relevant (PCF) and enable SSAO from depth.
2. **Explicit uniform locations on `deferred.glsl`** — `fragData0/1/2` currently rely on linker-assigned declaration order; add `layout(location=0/1/2)` to remove the driver fragility. Low-risk hardening, good first commit.
3. **SPIR-V shader loading (4.6 feature)** — offline-compiled loads via `glShaderBinary`; low priority, driver support varies.
4. **Replace corrupted texture assets** — most `res/` textures are 130-byte placeholders; magenta fallbacks still show through. Real assets or procedural gen.

See `AGENTS.md` "Post-4.6 Modernization Backlog" for the same list with more detail and trigger conditions.

## Failure modes & rollback (short)
- Validator passes but runtime fails → real vs/fs link mismatch, or an include missing from one of the two trees (`res/shader/`, `res/ltheory-test-master/res/shader/`).
- Black screen / purple streaks → no program started under core (Finding 2 above).
- White bg/black models → deferred outputs lack explicit locations.
- Rollback: revert the two-line context+`#version` change and any profile-mask flip; each stage is independent.
