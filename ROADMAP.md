# Limit Theory — Roadmap

The GL/GLSL 4.6 core ladder, the FMOD→miniaudio audio swap, and the library-currency pass are **complete**. The engine is fully 64-bit and runs the deferred+post rendering path on a modern core profile. What's left is feature investment, not correctness. Ordered roughly by expected impact / dependency order; each item is a self-contained project.

**This file is the ONLY tracker.** The finished design and implementation records live in `docs/` (`docs/ltheory-planets.md`, `docs/procedural-space-environment.md`, `docs/ssao-gtao-implementation.md`, `docs/fog-nebula-implementation.md`, `docs/multithreading.md`, `docs/debug-panel-update.md`, `docs/SDL_Migration.md`, `docs/ltheory-node-ui.md`, `docs/ltheory-ui-gui-research.md`) — those are the *why*, and they stay exactly as they were written. Anything still open is listed **here**, so nothing hides in a 165 KB file.

## Completed
- **HDR + tonemapping (#1)** — done & **visually signed off 2026-09-09** (exposure meter on-target: `max` ~1.5–3, `lit` ~0.2–0.5, `over` ~1–5%; ACES validated in-game). RGBA16F deferred+post chain; Karis-weighted mip bloom (additive pre-tonemap); selectable AgX/ACES/Filmic/Khronos operators + `2^EV` exposure + sRGB dither in one `filter/tonemap` pass (`res/shader/include/tonemapping.glsl`); grain/vignette/aberration/radialblur re-wired onto the chain. Includes the exposure **meter** (`Renderer:meter`/`filter/exposure.glsl`, now opt-in via
  `postfx.exposure.meter`) that makes the tuning repeatable. **Auto-exposure was removed 2026-10-14**
  (`postfx.autoexposure.*`, `Renderer:autoExposureEV`): it never worked, because `Time_GetRaw()` returns epoch
  SECONDS and the code read it as ms (adaptation 1000x too slow, and its meter's readback fired once per
  100 s), and a working version would pump the screen across a planet-surface/empty-space boundary. Use
  `postfx.exposure.ev` by hand.
- **Sun lighting, directional shadows, PBR finish (hdr: commit)** — directional sun pass (`light/dir.glsl`, additive over the ambient) + warm hemisphere fill (`light/global.glsl` `sunColor*sunFill*(0.5+0.5·N·L)`) + dust-cloud backlight, driven by `render.sun.{enable,intensity,fill,warmth}` (warmth lerps white→starColor orange). Camera-centered **directional shadow map** (`GameView:renderSunShadow`, Depth32F ortho along `-starDir`, 2× point-light resolution; PCF in dir.glsl fixed for reciprocal texel sampling and correct lit step integration; ambient stays) — `render.sun.{shadows,shadowRange}`, reusing `render.shadow.{bias,scale,radius}`. **PBR finish:** dielectric GGX specular (`lighting.specular`, applied in dir + point passes), Ice now lit by point lights, IBL intensity scale (`lighting.ambientEnv`).
- **Color Grading Micro-Knobs (#14 part)** — done & **signed off 2026-09-11** (`res/shader/include/tonemapping.glsl`, `filter/tonemap.glsl`, `Renderer.lua`): added linear-space color grading knobs (`postfx.color.sat`, `postfx.color.contrast`, `postfx.color.temp`, `postfx.color.tint`) operating post-exposure and pre-tonemap. Auto-registered in `Settings` and exposed under the `postfx` section in `DebugWindow`.
- **UI above the post chain (hdr: commit)** — `Renderer:startUI/endUI/compositeUI(post)` + `filter/ui_overlay.glsl`: reticle/HUD/exposure-meter render *after* tonemap+sharpen out of a dedicated `uiBuffer`. Exposure meter reads scene-only.
- **Sharpen sliders (hdr: commit)** — `postfx.sharpen.{strength,radius}` (sigma = radius×0.5), seeded from `Config.gpu.sharpenStrength/sharpenRadius`. Visible on asteroid close-ups and planets.
- **Debug-panel immediate-draw batching (#15)** — done 2026-09-08 (see `debug-panel-update.md` §S4): flat batch, glyph atlas, widget-shader batching. Imms ~5,300 → **~340**, draws 46 → 42 (~1.7 ms). Faster scroll speed enabled (`scrollView:setScrollSpeed(36)`).
- **Multithreaded render/submit (#10)** — done 2026-09-04 (see `multithreading.md`): pre-flight + Phases 0/1/3/4/5 (CPU batching, worker-built batches, persistent pooling).
- **SDL2 → SDL3 (#9)** — done 2026-09-03: system SDL3 3.4.14, GL 4.6 core on native Wayland.
- **SSAO / GTAO (#2)** — done & **signed off 2026-09-10/11** (branch `ssao-gtao`): 3-pass GTAO — half-res view-ray (`filter/aoview.glsl`), full cosine-windowed sky horizon integral with 64×64 blue-noise slice rotation (`filter/ao.glsl`), depth-aware full-res upsample+denoise (`filter/aoblur.glsl`). Upgraded with LOD 0.0 depth sampling, sky gating ($d \ge 900000$), and center-tap fallback on edge discontinuities ($w_{\text{sum}} < 1\text{e-}4$) to eliminate silhouette outlines. Material-aware **ambient-only** dispatch in `light/global.glsl`.
- **Sectors, regions, places and the one map** — done (Phases A–H of
  `docs/procedural-space-environment.md`): a sector is a named, seeded place; a
  region is a named volume inside it with an EXACT Apollonius boundary (a
  sphere, solved in closed form, not sampled); the HUD names the sector and
  the region and points at the next boundary; the map is ONE node graph whose
  outermost level is the galaxy (V) and whose levels below are the sector
  (F10) and a region (double-click). Regions are clickable and drillable.
  Every level shares one camera, one fit and one drill stack.
- **Jumpgates / inter-sector travel** — done: the old game's wormholes, ported
  from the recovered `Warping/` source. A gate is a PAIR of linked endpoints
  (one in each of two sectors) and the travel is a DOCK — fly into the glow,
  press F, and the ship is in another sector, which regenerates its planet,
  its sky and its rocks from its own seed. The gate graph is the old game's
  shape: the union of TWO MINIMUM SPANNING TREES over the sectors, with
  randomised edge weights (`tools/validate_sectors.lua` checks it is
  connected, spread, mutual, and identical with the JIT on and off).
- **A shipped look, and a look that is a look** — done 2026-10-21: the
  debug panel's own settings snapshot is now the SHIPPED default for every
  seed (in `Config.gpu`, not in a local preset), verified key-by-key against
  a live snapshot of the running game. See `docs/ltheory-planets.md` §11.20.
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
   - **The design note is `docs/ltheory-ui-gui-research.md`** — the map of the
     three GUI systems (HmGui, the engine's own ImGui, and `script/UI/`), the
     guide to which to use, and the widget API. It was corrected against the
     code in 2026-10-22: it had claimed the game does not use the UI
     framework at all (it does — `GameView` extends `UI.Container`), and its
     "complete working example" called a `UI.Column` widget that does not
     exist, built sliders with the wrong signature, and drew circles with a
     `Draw.Circle` the engine does not have.
   - **There is now a working demo app: `script/App/UI_Demo.lua`**
     (`./run.sh UI_Demo`) — a radar, a reticle with target brackets, ship
     status, flight controls, an inventory and a sector map, built from the
     framework's own widgets over a simulated ship. It is the reference the
     main menu and the settings screen should be built from, and it is where
     the layout idiom is written down: a container does not flow its children
     (use a one-column Grid), a widget that sizes to its content needs
     `setStretch(0, 0)`, and the canvas places children by `setAlign`
     fraction.
15. **Places in the regions** — ✅ **done**. Every region now has a PLACE: a
   station scaled down to an outpost, at the region's centre, named after the
   region and for what it is — a mining RIG in a belt, a YARD with a factory,
   a RELAY in a veil. Every one has a market. The lanes now run to the
   places, which is what gives them a purpose: "Nearest lane to Hogatuge
   Rig" is a place. Regions also have a KIND (belt/yard/veil) which decides
   what is in them, and a sector is guaranteed a belt and a yard so it always
   has something to mine and somewhere to sell. See
   `docs/procedural-space-environment.md` §29l.
   - **The economy's last mile is walked too.** `Market:sell` and
     `Market:buy` now move the goods and the credits between the two
     parties (the matching loop only moved order counts), and there is a
     MARKET PANEL at the dock: the station's name, the player's credits
     and hold, the price the market will pay and will ask, and the keys
     that move things (R sells everything, T buys one). The loop end to
     end: mine the isotopes in a belt, sell them at a rig or a yard, buy
     the energy cells the reactors make. The prices are in
     `script/Game/Content.lua` with the items.
   - **Still missing:** the credits buy energy cells, and the energy cells
     have no use yet -- the ship's capacitor is not wired to them and there
     is nothing to upgrade. The economy runs; it does not yet lead
     anywhere. The **market's escrow** is also not ported: the old game's
     `Market/Market.cpp` escrowed a sell order's goods into a per-owner
     storage locker and a buy order's credits, and settled on the midpoint
     of the ask and the bid. The port does instant trades against standing
     orders, with the price walking the order book and each order settling
     on its own terms -- the price walk and the midpoint are in, the
     escrow is not.
16. **The ship's speed vs the sector's scale** — ✅ **done**: the thrust now
   buys **500 u/s** and the boost **1000** (the real top speed was 203 u/s;
   the hardcoded 100 in `Ship:getTopSpeed` had never matched the physics).
   A region is a minute away and the sector is two. The ramming damage, the
   chase camera's lead and the turning torques were all rescaled with it.
17. **A save format** — there is none: no `saveGame`, no `loadGame`. The map
   holds the sector seeds in memory and that is the whole of "the sector
   remembers itself".
18. **Gas giants (W7d)** — deferred 2026-10-14. A banded generator plus a
   no-solid-surface path. It was explicitly the expensive one, so it was
   held back until the FPS budget had been re-measured under load. The
   design is in `docs/ltheory-planets.md` §11.3.
19. **Atmosphere entry / landing (W7e)** — deferred 2026-10-14. Gameplay
   rather than rendering, and blocked by nothing:
   `exp(-altitude/scaleHeight)` → drag/lift → landing zones. Same doc,
   §11.3.

## Platform & systems
11. **Jolt Physics** — Modern SAP broadphase + multithreaded physics replacement if Bullet 3 becomes a bottleneck.
12. **Vulkan** — Modern low-level target (renderer rewrite; post-GL path settlement).

## Vastness & atmosphere systems
13. **Procedural streaming + LOD crossfade for endless sectors (atmosphere / vastness)** — Endless sector streaming with frustum + distance culling, LOD crossfading (`VisibleLodMesh`), and horizon fading. (The "distance haze pass" this used to name was REMOVED — it hazed by depth alone, modelling an unbounded exponential atmosphere, so it applied ~50% of haze to a planet 137k away across ~120k of vacuum and halved the planet's local contrast. The volumetric pass already scatters correctly, over the medium that actually exists. See `docs/ltheory-planets.md` §11.6.) The asteroid field already streams per chunk with a fragment-discard curtain; what is left is the near/mid/far representation tiers and the crossfade.
    - **13a the shared SpaceField** — ✅ **done**. The `SpaceField` module
      (the shared hash, a continuous multi-scale value-noise field) was
      written for this and existed; what was missing was that there were TWO
      fields that did not know about each other. They are now ONE: the
      archetype is the MACRO and the SpaceField's noise is the MESO, so a
      region has character *and* variety inside it, and `System:fieldAt` is
      the only way anything asks "what kind of place is this" — the gas,
      the rocks, the dust, the lightning and the shafts all go through it.
      Three channels still have no consumer, and they need a game system
      rather than a shader: `starVisibility` (the medium's extinction of
      the stars), `turbulence` (the plumes' warp) and `radiation` (a
      region's hazard).
    - **13f region personality** — ✅ **done**. The regions now have a FIELD:
      the archetype's gas density, storminess, light, rock count and ore,
      blended across the boundary by the Apollonius membership (so the
      transition is continuous and there is no seam), and EVERY channel has
      a consumer reading the SAME field — the gas takes the region's
      density and leans 35% toward the region's hue, the asteroid field
      takes the rock count and the ore, the lightning takes the
      storminess, the god rays take the light. So they cannot disagree
      about what kind of place they are in. The archetypes' numbers are no
      longer dead. See `docs/procedural-space-environment.md` §29k.
      - **The skybox is one cube per sector**, so the region's colour only
        tints the plumes — a few per cent of the frame rather than a change
        of place. Making the sky regional would be a cube per region, or a
        hue rotation of the skybox sample.
      - **DECIDED (2026-10-21): leave it.** One cube per sector is right —
        a sector should not change its sky, and in real space it would not
        change character within one. The region's colour tints the plumes,
        which is where the medium is anyway. Not an open item.
    - **The field's cost is the cube of its radius** — the loaded volume is
      `(reach/4)³` of a reach-4 field, so the reach is the one big lever: a
      reach of 6 chunks (15 km) is 21% of the entities of a reach of 10
      (25 km), and the per-chunk density is another (halving it halves the
      entities and makes the field sparser). Both are one line in the debug
      panel (`gen.asteroidField.{loadRadius,fadeStart,perChunk}`), and both
      are the player's to pull — the fade band that hides the boundary is
      what the fade start is for. What was a bug is fixed: the field's
      density used to swing 2.4× between a belt and a deep field (17,195
      entities against 7,030) because the archetype's `rocks` and the meso
      noise both multiplied on top; the rock count is now a narrow band and
      the ORE — which costs nothing, being the same rocks either way — is
      what makes a belt a belt.

## Known polish / tech debt (small, unbundled)
- **The `.glsl` dead-code review** — a dedicated pass over the shaders for
  dead branches and uniforms, recorded in `docs/ltheory-planets.md` §11.8 E.
  It is orthogonal (it touches no behaviour), so it rides with its own pass
  rather than being smuggled between items.
- **The two seed/hash refactors** — one shared CPU/GPU hash, so the CPU and
  the GPU cannot disagree about a world's noise; and one seed field for the
  skybox, the anchors and the medium instead of three. Both are recorded in
  `docs/ltheory-planets.md` §11.1a.
- **Two look decisions that need a human** (`docs/ltheory-planets.md` §11.5):
  the ship's hull is `Material.Metal`, which is specular-only, so the
  silhouette reads — `Diffuse`/`Ice` is the lever if it should be lit like
  the asteroids; and the lava emission tops out at the albedo clamp, so
  letting the emissive exceed 1 would put bloom on molten surfaces.
- **Audio polish**: Fixed `ThrustController.lua` thruster audio by correcting `set3DMinMaxDistance` attenuation parameters (`maxDist` fixed from `0` to `1000`) and adding Exponential Moving Average (EMA) volume smoothing to prevent zipper noise. Pre-load rapid SFX buffers once with `ClonePlayFree` for dogfight audio.
- **Dead code**: the unreferenced nebula generators (`gen/nebula2/3/4_weak`),
  `gen/clouds_cube`, the `ItemCount` class, a dozen unused file-locals, and
  two dead uniforms (`bloompre.maxBrightness`, which was never uploaded and
  whose in-shader fallback always ran, and the tonemap's lens-dirt overlay,
  whose branch was provably unreachable behind a GLSL default initializer) are
  all gone. `genColor` is no longer dead either -- the W7c biome blend
  consumes it as the moisture field.
- **Perf hardening:** Pooled `self.anchorBytes` inside `Renderer:volume()` to eliminate 768-byte allocations per frame in nebulae. Restored missing `shader:start()` call in `Renderer:presentAll()`.
