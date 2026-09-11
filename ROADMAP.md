# Limit Theory — Roadmap

The GL/GLSL 4.6 core ladder, the FMOD→miniaudio audio swap, and the library-currency pass are **complete**. The engine is fully 64-bit and runs the deferred+post rendering path on a modern core profile. What's left is feature investment, not correctness. Ordered roughly by expected impact / dependency order; each item is a self-contained project.

## Completed
- **HDR + tonemapping (#1)** — done & **visually signed off 2026-09-09** (exposure meter on-target: `max` ~1.5–3, `lit` ~0.2–0.5, `over` ~1–5%; ACES validated in-game). RGBA16F deferred+post chain; Karis-weighted mip bloom (additive pre-tonemap); selectable AgX/ACES/Filmic/Khronos operators + `2^EV` exposure + sRGB dither in one `filter/tonemap` pass (`res/shader/include/tonemapping.glsl`); grain/vignette/aberration/radialblur re-wired onto the chain. Includes the exposure **meter** + **auto-exposure** (`Renderer:meter`/`filter/exposure.glsl`, `postfx.autoexposure.{enable,key,minEV,maxEV,speed}` with live EV tracking) that make the tuning repeatable.
- **Sun lighting, directional shadows, PBR finish (hdr: commit)** — directional sun pass (`light/dir.glsl`, additive over the ambient) + warm hemisphere fill (`light/global.glsl` `sunColor*sunFill*(0.5+0.5·N·L)`) + dust-cloud backlight, driven by `render.sun.{enable,intensity,fill,warmth}` (warmth lerps white→starColor orange). Camera-centered **directional shadow map** (`GameView:renderSunShadow`, Depth32F ortho along `-starDir`, 2× point-light resolution; PCF in dir.glsl fixed for reciprocal texel sampling and correct lit step integration; ambient stays) — `render.sun.{shadows,shadowRange}`, reusing `render.shadow.{bias,scale,radius}`. **PBR finish:** dielectric GGX specular (`lighting.specular`, applied in dir + point passes), Ice now lit by point lights, IBL intensity scale (`lighting.ambientEnv`).
- **Color Grading Micro-Knobs (#14 part)** — done & **signed off 2026-09-11** (`res/shader/include/tonemapping.glsl`, `filter/tonemap.glsl`, `Renderer.lua`): added linear-space color grading knobs (`postfx.color.sat`, `postfx.color.contrast`, `postfx.color.temp`, `postfx.color.tint`) operating post-exposure and pre-tonemap. Auto-registered in `Settings` and exposed under the `postfx` section in `DebugWindow`.
- **UI above the post chain (hdr: commit)** — `Renderer:startUI/endUI/compositeUI(post)` + `filter/ui_overlay.glsl`: reticle/HUD/exposure-meter render *after* tonemap+sharpen out of a dedicated `uiBuffer`. Exposure meter reads scene-only.
- **Sharpen sliders (hdr: commit)** — `postfx.sharpen.{strength,radius}` (sigma = radius×0.5), seeded from `Config.gpu.sharpenStrength/sharpenRadius`. Visible on asteroid close-ups and planets.
- **Debug-panel immediate-draw batching (#15)** — done 2026-09-08 (see `debug-panel-update.md` §S4): flat batch, glyph atlas, widget-shader batching. Imms ~5,300 → **~340**, draws 46 → 42 (~1.7 ms). Faster scroll speed enabled (`scrollView:setScrollSpeed(36)`).
- **Multithreaded render/submit (#10)** — done 2026-09-04 (see `multithreading.md`): pre-flight + Phases 0/1/3/4/5 (CPU batching, worker-built batches, persistent pooling).
- **SDL2 → SDL3 (#9)** — done 2026-09-03: system SDL3 3.4.14, GL 4.6 core on native Wayland.
- **SSAO / GTAO (#2)** — done & **signed off 2026-09-10/11** (branch `ssao-gtao`): 3-pass GTAO — half-res view-ray (`filter/aoview.glsl`), full cosine-windowed sky horizon integral with 64×64 blue-noise slice rotation (`filter/ao.glsl`), depth-aware full-res upsample+denoise (`filter/aoblur.glsl`). Upgraded with LOD 0.0 depth sampling, sky gating ($d \ge 900000$), and center-tap fallback on edge discontinuities ($w_{\text{sum}} < 1\text{e-}4$) to eliminate silhouette outlines. Material-aware **ambient-only** dispatch in `light/global.glsl`.
- **Volumetric Nebula & Participating Media (fog-nebula)** — done & **signed off 2026-09-11** (branch `fog-nebula`): 2-pass participating media with world-space snapped grid density, anisotropic Henyey-Greenstein scattering, and deterministic per-cell plume anchors (`NebulaVolumes.lua`). Resolved planet silhouette outlines and floating cube faces via Euclidean spherical falloffs, LOD 0.0 depth sampling, and 32-bit bitwise integer cell PRNG. `Renderer:volume` optimized with persistent `anchorBytes` pooling to eliminate per-frame GC allocations.

## Rendering & graphics
3. **Bindless textures / texture arrays** for the deferred material path — fewer state changes with many materials (recommended prerequisite before sector streaming #13).
5. **Volumetric atmosphere / planetary scattering** — upgrade the current rim-glow for planets by extending `medium.glsl` / `volume.glsl` with an exponential atmospheric density falloff curve $\rho(r) = \rho_0 \exp(-r / H)$.
6. **SPIR-V shader loading (4.6 feature)** — offline-compiled loads via `glShaderBinary`/`glSpecializeShader`; low priority.
14. **Graphics-options parity** — Remaining items to add:
    - **Motion blur**: Camera-velocity buffer pass from `eyeVel`.
    - **Fast Anti-Aliasing (FXAA / SMAA)**: Lightweight post-pass alternative to 2x/4x SuperSampling for low-end GPUs.
    - **Anamorphic Lens Flares**: 1D horizontal threshold blur pass for engine thrusters, stars, and specular glints.
    - **Screen-Space Reflections (SSR)**: Real-time metallic reflection pass on ship hulls and station geometry.
    - **AMD CAS (Contrast Adaptive Sharpening)**: Edge-preserving sharpening pass to replace Gaussian blur-sharpening.

## Content & gameplay
7. **Procedural content expansion**: L-system stations, SDF planets with biome terrain, procedural nebulae, procedural sky/env cubemaps.
8. **Game screens**: Main menu / settings screen app on `script/UI/`.

## Platform & systems
11. **Jolt Physics** — Modern SAP broadphase + multithreaded physics replacement if Bullet 3 becomes a bottleneck.
12. **Vulkan** — Modern low-level target (renderer rewrite; post-GL path settlement).

## Vastness & atmosphere systems
13. **Procedural streaming + LOD crossfade for endless sectors (atmosphere / vastness)** — Endless sector streaming with frustum + distance culling, LOD crossfading (`VisibleLodMesh`), and horizon fading via the landed distance haze pass (`postfx.fog.*`).

## Known polish / tech debt (small, unbundled)
- **Audio polish**: Fixed `ThrustController.lua` thruster audio by correcting `set3DMinMaxDistance` attenuation parameters (`maxDist` fixed from `0` to `1000`) and adding Exponential Moving Average (EMA) volume smoothing to prevent zipper noise. Pre-load rapid SFX buffers once with `ClonePlayFree` for dogfight audio.
- **Perf hardening:** Pooled `self.anchorBytes` inside `Renderer:volume()` to eliminate 768-byte allocations per frame in nebulae. Restored missing `shader:start()` call in `Renderer:presentAll()`.
