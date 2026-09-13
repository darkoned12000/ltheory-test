# Nebula Fog / Dust Volume + Lightning Storm — Implementation Plan (branch: `fog-nebula`)

Goal: build a **participating-media renderer with stylized anisotropic nebula lighting** — not a named-after-one-aesthetic effect. Freelancer/Starlancer are the *visual reference*, not the implementation scope, because the same medium should later serve dust, gas, planetary haze, engine smoke, storm volumes, and nebulae.

Concretely: fly through drifting volumetric dust and nebula plumes that occlude the stars, glow against the sun with anisotropic forward scatter, get cut by independent god-rays, and are torn periodically by **lightning storms** — a branching bolt, a white-hot flash, and a *local* volumetric light that makes the cloud around the strike glow and decay. All opt-out, Perf-gated, and equivalence-tested like GTAO was.

Base branch `main` (GTAO + distance haze merged). Plan opened **2026-09-10**; revised **2026-09-11** (§2, §3, §10).

---

## 1. The asks (verbatim intent, kept as features)

1. **Volumetric nebula/dust** — fly-through volume with parallax, not billboards or a 2D tint.
2. **Sun-lit dust with anisotropy + god-rays** — forward-scatter phase, independent shaft pass.
3. **Stars occluded by dust** — the sky behind a thick bank dims (`scene * T + inscatter`, never `scene + additive`).
4. **Lightning storm spike** — bolt + flash + the dust lights up **locally** at the strike, then decays; a weather event, not a texture; audio hook data-driven behind the visual gate.
  - To bring "electricity and life" into nebulae (roadmap #4), the volumetric pipeline handles lightning strikes via a dynamic LightingEvent struct:  
  - Local Energy Injection (LightingEvent)When an electrical storm triggers in a sector, the Lua game loop creates a temporary event record:
    ```Lua 
    local strike = {
      pos = Vec3f(x, y, z),
      color = Vec3f(0.4, 0.8, 1.0), -- Hot Electric Blue
      energy = 15.0,                -- Intensity multiplier
      radius = 3500.0,              -- Light flash radius
      duration = 0.4                -- Seconds to decay
    }
    ```
  - Volumetric Light Flash inside volume.glsl
    - Inside the half-res raymarch pass, volume.glsl evaluates point-light attenuation from active lightning strikes:
        $$\text{lightningLight} = \frac{\text{strike.color} \cdot \text{energy}}{\text{dist}^2 + 1.0} \cdot \exp(-\text{dist} \cdot \sigma_t)$$
    - Because energy scatters through the local dust, a lightning bolt illuminates the interior of the cloud, causing surrounding gas tendrils to flash white-hot and slowly decay.
  - Camera & Bloom Interaction
    - Powerful strikes instantly trigger auto-exposure adaptation (Renderer:meter) and feed high-luminance pixels into Karis bloom (Renderer:bloom), producing realistic camera lens glare and glowing cloud rims.
5. **Nebula as sector content** — anchor volumes (real local clouds you can orbit), palette from the same generator that makes the sky.
6. **Opt-out + Perf-gated + A/B-toggleable + debug modes** — off = bit-identical frame; a debug visualization enum so tuning stops being "summon screenshots by feel".

---

## 2. Review feedback & architectural corrections incorporated

1. **Density field is world-space, not camera-anchored** — `density(worldPos)`, maintained in a camera-following cell that *snaps on a large grid* (world pos = eye + dir $\cdot$ t). Camera-space lobes cause swimming and break streaming.
2. **No multi-octave FBM in Phase 1** — start with 2 noise evals (low-freq coherent + higher-freq modulation). Detail comes from lighting + jitter.
3. **Transfer/scattering equation is the explicit contract (ADR math)** — $\sigma_t$ (absorption + scattering) separated from $\sigma_s$ (scattering); accumulation via $T *= \exp(-\sigma_t \cdot \rho \cdot ds)$ and $\text{inscatter} += T \cdot \sigma_s \cdot \rho \cdot \text{lighting} \cdot ds$; composite $\text{scene} \cdot T + \text{inscatter}$.
4. **Nested full sun raymarch is prohibited in Phase 1** — `sunTrans` is a fixed-cost approximation. 24 camera steps $\times$ 24 sun steps would blow the budget.
5. **God-rays are a separate pass boundary** — "what does the medium do to light" vs "where do we emphasize directional shafts" are separate products with separate A/B knobs.
6. **Anchors use a bounded active-volume interface, not an ever-growing shader loop** — CPU spatially culls `NebulaVolume` records, uploads only volumes intersecting `[camera ± volumeDist]`, shader iterates that fixed list ($\le 16$).
7. **The volume must not sample the rendered envMap as its radiance** — split the concepts: **palette** (medium albedo, from generator's seed/ramp) and **illumination** (actual lighting: `sunColor` + `irMap` ambient).
8. **Plumes require Euclidean spherical distance falloff (No $L_\infty$ AABBs)** — anchor density envelopes must use $\|p - c\| / r$ with $C^1$ Hermite `smoothstep(1.0, 0.0, dist)` falloffs. Chebyshev box metrics ($L_\infty$) create 90-degree box corners floating in space and are strictly forbidden.
9. **Depth sampling must use LOD 0.0** — both pass A (`volume.glsl`) and pass B (`volblur.glsl`) must sample `texDepth` at base level `0.0`. Bilinear filtering on depth mips across silhouettes causes depth bleeding and premature ray cutoffs.
10. **Bilateral upsample fallback on depth edges** — when 3x3 bilateral gather weights sum to $w_{\text{sum}} < 1\text{e-}4$ at sharp depth edges (e.g., planet silhouette vs. sky), `volblur.glsl` must fall back directly to the center tap `texelFetch(texVol, pH, 0)`. Dividing zero accumulated color by $\epsilon$ creates pure black silhouette outlines.
11. **Lua hash determinism via integer grid** — `NebulaVolumes.lua` must use 32-bit bitwise integer hashing (`hash32`) operating on cell integer coordinates $(i_{cx}, i_{cy}, i_{cz})$ rather than `math.sin` on float world positions to avoid precision loss at large world origins.
12. **Zero-allocation anchor upload** — `Renderer:volume` uses a persistent `self.anchorBytes` buffer instead of allocating 768-byte buffer instances per frame on the C-FFI heap.
13. **Off = renderer-disabled, not density-zero** — test `Config.gpu.nebula = 0` and `nebula.enable = false`, not `density = 0`.
14. **Per-piece perf budget**: base volume $\le 0.65$ ms, reconstruction $\le 0.20$ ms, god-rays $\le 0.30$ ms, lightning $\le 0.10$ ms $\rightarrow$ normal target $\le 0.95$ ms @ 1024x768 2xSS.

---

## 3. Architecture

One half-res world-space volume pass $\rightarrow$ depth-aware bilateral reconstruction with silhouette edge fallback $\rightarrow$ independent god-ray emphasis $\rightarrow$ haze $\rightarrow$ meter $\rightarrow$ tonemap.
```
GBuffer / Lit
│
▼
Volume raymarch      (half-res, world-space density, LOD 0.0 depth, sun scattering + irMap)
│
▼
Reconstruction       (full-res, depth-aware 3x3 gather, LOD 0.0 depth, center-tap edge fallback)
│
▼
God-ray emphasis     (separate low-res shaft pass, own A/B)
│
▼
Haze ──► Exposure meter ──► Tonemap
```

**Medium equation:**

$$\rho(p) = \text{mediumDensity}(p) + \text{anchorEnvelope}(p)$$

$$T *= \exp(-\sigma_t \cdot \rho \cdot ds)$$

$$\text{inscatter} += T \cdot \left(1 - \exp(-\sigma_t \cdot \rho \cdot ds)\right) \cdot \frac{\sigma_s}{\sigma_t} \cdot \left(\text{sunColor} \cdot P(g, \theta) + \text{irMap}\right) \cdot \text{albedo}$$

$$\text{out.rgb} = \text{scene.rgb} \cdot T + \text{inscatter}$$

**Termination & Sky Gate:** $t_{\text{cap}} = (d_{\text{depth}} \ge 900000) ? v_{\text{dist}} : \min(d_{\text{depth}}, v_{\text{dist}})$. Sky pixels ($d \ge 900000$) do not truncate rays early, allowing clouds to occlude stars while preventing double-integration past infinity.

---

## 4. Phases & Status

### Phase 0 — Renderer seam + debug views
- Stub `Renderer:volume()`: half-res RT, LOD 0.0 depth, identity march, depth-aware upsample.
- `nebula.debug` view enum: `off | density | transmittance | lighting | steps | anchors`.

### Phase 1 — Low-frequency participating medium & anisotropic scattering
- World-space snapped cell density, 2 value-noise evals, time drift, exact star transmittance $X \cdot T$.
- Anisotropic Henyey-Greenstein phase $P(g, \theta)$ with $g \approx 0.758$ plus `irMap` ambient.

### Phase 2 — Anchor volumes & spatial culling
- `NebulaVolumes.lua` cell-lattice generator ($CELL = 12000$, 32-bit integer PRNG, $\le 16$ nearest volumes uploaded to `texAnchors` RGBA32F).
- Euclidean spherical plume density with smoothstep falloffs.

### Phase 3 — God-rays (independent product)
- Standalone low-res shaft pass from `starDir`; own A/B on/off controls.

### Phase 4 — LightningEvent & local volumetric flash
- Consume `{position, color, energy, radius, falloff}` as a local light source inside `volume.glsl`.

### Phase 5 — Polish & performance validation
- Worst-case budget audit, quality matrix verification, documentation closure.

---

## 5. Status Log

- **2026-09-10** — Plan opened on branch `fog-nebula`. External review incorporated.
- **2026-09-11** — **Phases 0, 1, and 2 shipped.** Initial user testing revealed two visual artifacts:
  1. *Black line around planet radius*: Caused by bilateral upsample division-by-zero on sharp depth discontinuities in `volblur.glsl`, combined with depth mip linear filtering in `volume.glsl`.
  2. *Floating cube faces & grid lines*: Caused by $L_\infty$ Chebyshev box metrics in `anchorEnvelope`, sign loss in `cloudSection` via `abs(rd)`, and floating-point `math.sin` hash precision loss in `NebulaVolumes.lua`.
- **2026-09-11** — **Artifact Root Causes Resolved & Validated**:
  - `NebulaVolumes.lua`: Switched to integer cell coordinate hashing via 32-bit bitwise operations (`hash32`).
  - `medium.glsl`: Replaced Chebyshev box metric with Euclidean spherical distance (`length(p - c.xyz) / r`) and $C^1$ smoothstep falloff. Fixed signed ray inverse calculation in `cloudSection`.
  - `volume.glsl`: Standardized depth sampling to LOD `0.0`. Corrected step transmittance integration order.
  - `volblur.glsl`: Standardized depth sampling to LOD `0.0`. Normalized sky depth comparisons ($d \ge 900000 \rightarrow 1000000$). Added edge fallback (`wsum < 1e-4`) to center tap `texelFetch(texVol, pH, 0)`, eliminating black silhouette artifacts.
  - `Renderer.lua`: Cached persistent `self.anchorBytes` memory buffer to eliminate per-frame C-FFI heap allocations inside `Renderer:volume()`.
  - Validator 130/0 @ 460 Core; boot and frame presentation clean across all debug modes.
- **2026-09-13** — **Phase 3 (God-rays) shipped + review fix**:
  - **Review found + fixed a Phase 2 bug**: `NebulaVolumes.lua` stored `local ccz = icy * CELL` (y-cell for z), collapsing every plume's z-position onto a y gridline and killing z-parallax; corrected to `icz * CELL`.
  - `filter/godrays.glsl` (new): independent quarter-res worldray march accumulating only the sun's forward scatter (`hgPhase(godA ≈ 0.92)`), depth/sky-gated exactly like `volume.glsl`; outputs `(shaft, T)`.
  - `filter/godblur.glsl` (new): 16-tap radial crawl toward the sun uv (`exp2(-2i)` weights), composite `scene + acc * godStrength` (mode 0) or raw shaft ×8 debug (mode 1).
  - `Renderer:godrays(med)` two-pass (quarter-res `godView` RGBA16F march → full-res integrate/composite into `buffer1`, `self:swap()`), settings `postfx.godrays.{enable,strength,g,debug}` (debug is a 1-based Settings enum — `(idx-1)` maps to the shader mode, mirroring `volMode`), `godView`/`volView` tied into the renderer release path.
  - `GameView.lua` call site between reconstruction and haze: sun uv from `camera:worldToNDC(camera.pos + starDir·1e5)`, mirrored behind camera, rim-clamped; `'Shaft'` debug bypasses the on/off gate.
  - Validation: **135/0 @ 460 Core**; clean boots; same-frame strength A/B (temp 3-band split) showed scene+shaft ×8 → +18.7 luma, ×1 → +9.6, ×0 → 0 — shaft live, strength knob lands.
  - Debugging note: the shaft read back all zeros for two sessions — the root cause was a **missing `volDensity` uniform in pass A** (`mediumDensity()` returns `volDensity * d`; default 0 ⇒ the whole medium disappears). The march samples the density field only under that gate. When probing a like this, check the medium's own gain uniforms first before suspecting marching or readback.
