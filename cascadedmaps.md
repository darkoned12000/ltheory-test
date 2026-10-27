# Cascaded Shadow Maps (CSM), God Rays & Performance Fixes

## 1. Cascaded Shadow Maps (CSM)

### Problem

The sun's directional shadow originally used one orthographic map covering
the entire `render.sun.shadowRange`. Its texels were visible on the ship and
nearby asteroids, especially with the camera facing the sun. Increasing the
single map resolution helped but did not provide enough detail over both near
and distant world geometry.

### First implementation and why it was insufficient

The initial three-map implementation used concentric, camera-centered boxes
with different radii, then selected a map by Euclidean distance from the
camera. This was an approximation, **not proper CSM**: it neither fitted each
map to a camera-frustum slice nor used view-space depth for cascade selection.
Playtesting continued to show coarse shadows and pixelation.

### Corrected implementation (current on `cascadedmaps`)

#### Frustum slices

`GameView:renderSunShadow` obtains the camera frustum corners by unprojecting
NDC corners through `mProjInv`, scaling their view-space rays to each split
depth, and transforming them to world space with `mViewInv`.

Default view-depth splits:
- Near: `0.1–1000` world units
- Mid: `1000–3000`
- Far: `3000–render.sun.shadowRange` (default `5000`)

Splits are reduced proportionally if the configured range is smaller.

#### Light-space fit and stability

Each slice is projected onto the sun-aligned light-space basis. The orthographic
square is fitted to the slice's light-space X/Y bounds, rather than using a
large camera-centered sphere. The projection center is snapped to shadow-texel
increments to reduce shimmer as the camera moves. The light-space depth range
is extended sunward to retain occluders in front of the receiver slice.

Each cascade uses the configured shadow-map resolution (default `2048`,
`Depth32F`). Cascade selection uses positive view-space depth:
`dot(worldPosition - eye, cameraForward)`. Shadow factors are smoothly blended
across each split boundary.

---

## 2. God Rays Shadow / Silhouette Artifacts

### Root cause diagnosis

Playtesting with **Sun Light** off and **God Rays** toggled on/off proved that
the detached, blocky ghost silhouettes under the ship and asteroids when facing
the star were produced by the quarter-resolution God Rays pass (`filter/godrays.glsl`
and `filter/godblur.glsl`), **not** the cascaded shadow maps (`light/dir.glsl`
only shadows opaque surface lighting; the volumetric passes do not sample the
shadow maps).

Multiple issues in the God Rays pipeline combined to produce the artifacts:

1. **Cross-silhouette radial gathering & linear depth averaging:**
   - `godrays.glsl` sampled `texDepth` (`zBufferL`) with linear filtering at
     quarter resolution, averaging foreground silhouettes with far sky depth.
   - `godblur.glsl` radially gathered taps toward the sun without depth gating
     and fell back to ungated bilinear upsampling at edges.
2. **Symmetric/binary depth rejection on small occluders:**
   - Asteroids narrower than a quarter-res texel owned no texel matching their
     depth; rejecting all taps to zero left a sharp black cutout ringed by
     clamped-bright sky haze, which bloomed into a bright highlight rim.
3. **Radial crawl dips across occluder holes:**
   - The quarter-res shaft buffer legitimately has dark holes where rays hit
     asteroids/ships. As sky pixels crawled toward the sun across those holes,
     averaging the dark texels dragged sky brightness down into detached dark
     smears away from the sun.
4. **Unbound blue-noise dither texture (`texNoise`):**
   - `godblur.glsl` originally sampled `texNoise` with screen-normalized `uv`
     (stretching the 64×64 LUT ~30× across the screen), and `GameView.lua`
     did not pass `noise = self:getAoNoise()` into `self.renderer:godrays({...})`.
     With `texNoise` unbound, the sub-tap offset `t0` was constant across the
     screen, so all 8 radial taps landed on fixed positions and printed
     stepped horizontal band copies of the ship's silhouette below the ship.

### Fixes implemented

- **Point depth fetch in `filter/godrays.glsl`:** Quarter-res shaft texels use
  `texelFetch` on `texDepth` so silhouette texels never march to an averaged
  foreground/sky depth, and store `log2(max(dist, 1.0))` in alpha.
- **Asymmetric depth-aware upsample + small-occluder wrap + Edge Wrap (`filter/godblur.glsl`):**
  - `sampleShaftDepthAware` rejects only taps *behind* the receiver while
    preserving scatter in front of the receiver.
  - Spatial bilinear weights are normalized without renormalizing rejected
    depth weights back to full strength.
  - Small occluders (`receiverLogDepth + 2.0 < minTapLog` on the center tap)
    fall back to a smooth bilinear wrap instead of a hard black cutout.
  - Added controllable light-wrap feather at depth edges (`postfx.godrays.wrap`,
    `- Edge Wrap`).
- **Own-ray floor on sky receivers (`filter/godblur.glsl`):**
  - Sky receivers floor their gathered radial value at their own ray's shaft
    value (`acc = max(acc, centerV)`), eliminating dark radial dips dragged out
    of foreground occluders while keeping object receivers strictly gated.
- **Per-pixel blue-noise dither bound (`script/Game/GUI/GameView.lua`, `filter/godblur.glsl`):**
  - `GameView` now passes `noise = self:getAoNoise()` into `renderer:godrays({...})`
    and `godblur.glsl` fetches `texNoise` per pixel via `texelFetch`, breaking
    up coherent tap copies into fine noise.
- **Diagnostic debug views (`postfx.godrays.debug`):**
  - Extended enum options to `Off`, `Shaft`, `Raw Shaft`, `Depth Key`, `Dither`,
    and `Center Only`.
- **Updated God Rays defaults (`script/phx/util/Renderer.lua`):**
  - `Strength = 1`
  - `Anisotropy = 0.715`
  - `Soft Ceiling = 2.0`
  - `Edge Wrap = 0.085`

---

## 3. FPS Drop Investigation & Performance Fixes

### Reproduction & profiling (Seed `15556742952389292890ULL`)

On seed `15556742952389292890ULL` (`PHX_SEED=D7E4A74AC339B35A`, inside the
*Solar Verge* Shattered Belt with **9,848 streamed rocks**), frame rate had
dropped to **35–43 FPS** (`23.0–24.6 ms/frame` mean, `32.1 ms` p95).

Profiling 240 frames with `PHX_PROFILER=1` revealed that God Rays were not the
bottleneck (`Render.PostFx` total was `0.11 ms/frame`). Instead, two CPU/draw
bottlenecks scaled with the ~10,000-rock belt:

1. **`Render.SunShadow` (`7.15 ms/frame`, 27.2%) + `Shader_Start` (`1.73 ms/frame`, 6.6%) = `8.88 ms/frame`:**
   - `GameView:renderSunShadow` broadcast `Event.Render` across all ~9,848
     entities **three separate times** (nearly 30,000 Lua event dispatches and
     FFI position/radius queries per shadow update).
   - The cascade culling sphere radius was computed as
     `math.sqrt(halfSize^2 + depthExtent^2) * 2` and then multiplied by
     `math.sqrt(3)` again (`> 17,320` world units for all three cascades)
     instead of culling to each cascade's actual light-space orthographic box
     (`halfSize × halfSize × depthExtent`). Cascade 0 (`halfSize ≈ 600`) was
     submitting thousands of rocks outside its frustum that the GPU vertex
     shader transformed only to clip.
   - `VisibleLodMesh`, `VisibleMesh`, and `Planet` called `shadow:start()` and
     `shadow:stop()` on every single shadow-casting rock (~10,500 redundant
     `ShaderState_Start` / `Shader_Start` calls per frame).
   - `state.eye` in `renderSunShadow` was set to `cascadeCenter` instead of
     `camera.pos`, causing distant rocks near far cascade centers to draw at
     high LOD (`LOD 0`) in the shadow map.
2. **`Economy.Update` (`5.60 ms/frame` mean, `19.08 ms` max, 21.3%):**
   - In a belt region (`oreChance = 0.9`), ~90% of the ~9,848 streamed rocks
     carry `addYield` and register in `EconomyRegistry`.
   - `Economy:update(dt)` rebuilt `self.factories`, `self.flows`,
     `self.markets`, `self.traders`, `self.yields`, and every
     `Jobs.Mine(src, dst)` pair **every single frame**, allocating ~35,000 new
     Lua tables per frame (~2.1 million allocations/sec) and causing heavy
     LuaJIT GC stalls.
3. **`HUD.DrawTargets` (`1.42 ms/frame`, 5.4%):**
   - For every rock inside the view frustum (~1,500 rocks), `HUD:drawTargets`
     called `target:getPos()` a second time (allocating a new `Vec3f` after
     `scratchPos` was already filled for the frustum test) and allocated
     `Disposition.GetColor(disp)` even when `Config.ui.showTrackers` was `false`.

### Performance fixes implemented

- **Single-pass light-space orthographic cascade culling (`script/Game/Shadow.lua`, `script/Game/GUI/GameView.lua`, `script/Game/Event.lua`):**
  - Added `Shadow.cullSunCascades(world, boxes, out0, out1, out2)` which walks
    `world.children` **once**, projects each entity's position onto the shared
    light-space basis `(right, up, sunDir)` once, and buckets only the entities
    whose bounding sphere intersects each cascade's orthographic box
    `[-halfSize, halfSize] × [-halfSize, halfSize] × [-depthExtent, depthExtent]`.
  - `Shadow.isInMap` also enforces `state.shadowBox` when present.
  - `renderSunShadow` passes `self.camera.pos` as `state.eye` so shadow LODs
    track camera distance.
- **Hoisted `Material.Shadow():start()` / `stop()` (`GameView.lua`, `VisibleLodMesh.lua`, `VisibleMesh.lua`, `Planet.lua`):**
  - `renderSunShadow` and `renderShadows` bind `Material.Shadow()` once per
    shadow target (`state.shadowActive = true`), avoiding thousands of
    per-entity `Shader_Start` calls.
- **Versioned `EconomyRegistry` & pooled mining jobs (`script/Game/EconomyRegistry.lua`, `script/Game/Components/Economy.lua`):**
  - Added `Registry.versionFor(parent)` incremented on entity register/unregister.
  - `Economy:update(dt)` only rebuilds the cached entity lists and mining jobs
    when `Registry.versionFor(self.parent)` changes, and reuses pooled
    `Jobs.Mine` instances (`self.mineJobPool`) so chunk streaming while flying
    does not trigger allocation spikes.
- **Eliminated redundant allocations in `HUD:drawTargets` (`script/Game/Controls/HUD.lua`):**
  - Reuses `scratchPos` from the frustum check and only allocates
    `Disposition.GetColor` when tracker brackets/points are actually drawn.

### Measured before vs. after (Seed `15556742952389292890ULL`, 1920×1080, 9,848 rocks)

| Metric / Scope | Before | After |
| --- | ---: | ---: |
| Frame time (mean) | `24.62 ms` (**41 FPS**) | `9.15–14.89 ms` (**67–109 FPS**) |
| Frame time (p95) | `32.15 ms` | `9.86–16.23 ms` |
| `Render.SunShadow` | `7.15 ms/frame` | `0.80–1.07 ms/frame` |
| `Shader_Start` | `1.73 ms/frame` | `0.23 ms/frame` |
| `Economy.Update` | `5.60 ms/frame` (max `19.08 ms`) | `< 0.01 ms/frame` |
